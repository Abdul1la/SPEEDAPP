import assert from 'node:assert/strict';
import { test } from 'node:test';

import { addPoint, anonymous, call, nearbyUrl, registered, staff, useTestApp, BAGHDAD } from './helpers.ts';

const ctx = useTestApp();

async function reportedPoint(reporters = 1) {
  const owner = await anonymous(ctx.app);
  const point = (await addPoint(ctx.app, owner)).body.point;
  for (let i = 0; i < reporters; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'POST', `/v1/points/${point.id}/reports`, { token: t, body: { reason: 'fake', comment: `r${i}` } });
  }
  return { owner, point };
}

test('only staff can use the admin API', async () => {
  assert.equal((await call(ctx.app, 'GET', '/v1/admin/stats')).status, 401);
  const driver = await anonymous(ctx.app);
  const res = await call(ctx.app, 'GET', '/v1/admin/stats', { token: driver });
  assert.equal(res.status, 403);
  const mod = await staff(ctx, 'moderator');
  assert.equal((await call(ctx.app, 'GET', '/v1/admin/stats', { token: mod.token })).status, 200);
});

test('stats', async () => {
  const mod = await staff(ctx, 'moderator');
  await reportedPoint(1);
  const res = await call(ctx.app, 'GET', '/v1/admin/stats', { token: mod.token });
  assert.equal(res.body.points.active, 1);
  assert.equal(res.body.points.cameras, 1);
  assert.equal(res.body.reports.open, 1);
  assert.equal(res.body.users.total, 3); // moderator, owner, reporter
  assert.equal(res.body.last24h.points, 1);
});

test('report queue: keep the point', async () => {
  const mod = await staff(ctx, 'moderator');
  const { point } = await reportedPoint(3); // hidden by 3 reports
  const queue = await call(ctx.app, 'GET', '/v1/admin/reports', { token: mod.token });
  assert.equal(queue.body.reports.length, 3);
  assert.equal(queue.body.reports[0].point.id, point.id);
  assert.equal(queue.body.reports[0].point.status, 'hidden');
  assert.equal(queue.body.reports[0].point.statusReason, 'reports');

  const res = await call(ctx.app, 'POST', `/v1/admin/reports/${queue.body.reports[0].id}/resolve`, {
    token: mod.token,
    body: { action: 'keep_point', note: 'camera is real' },
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.point.status, 'active');
  assert.equal(res.body.point.reportCount, 0);
  const open = await call(ctx.app, 'GET', '/v1/admin/reports', { token: mod.token });
  assert.equal(open.body.reports.length, 0);
  const closed = await call(ctx.app, 'GET', '/v1/admin/reports?status=dismissed', { token: mod.token });
  assert.equal(closed.body.reports.length, 3);
});

test('report queue: remove the point (drivers stop seeing it)', async () => {
  const mod = await staff(ctx, 'moderator');
  const { point, owner } = await reportedPoint(1);
  const [report] = (await call(ctx.app, 'GET', '/v1/admin/reports', { token: mod.token })).body.reports;
  const res = await call(ctx.app, 'POST', `/v1/admin/reports/${report.id}/resolve`, {
    token: mod.token,
    body: { action: 'remove_point' },
  });
  assert.equal(res.body.point.status, 'removed');
  assert.deepEqual((await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: owner })).body.points, []);
  const again = await call(ctx.app, 'POST', `/v1/admin/reports/${report.id}/resolve`, {
    token: mod.token,
    body: { action: 'dismiss' },
  });
  assert.equal(again.body.error.code, 'already_closed');

  const audit = await call(ctx.app, 'GET', '/v1/admin/audit', { token: mod.token });
  assert.equal(audit.body.entries[0].action, 'report.remove_point');
  assert.equal(audit.body.entries[0].actor.id, mod.id);
});

test('moderators can edit, hide and restore any point', async () => {
  const mod = await staff(ctx, 'moderator');
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const hidden = await call(ctx.app, 'PATCH', `/v1/admin/points/${p.id}`, {
    token: mod.token,
    body: { status: 'hidden', speedLimit: 60 },
  });
  assert.equal(hidden.body.point.status, 'hidden');
  assert.equal(hidden.body.point.statusReason, 'moderator');
  assert.equal(hidden.body.point.speedLimit, 60);

  const list = await call(ctx.app, 'GET', '/v1/admin/points?status=hidden', { token: mod.token });
  assert.deepEqual(list.body.points.map((x: { id: string }) => x.id), [p.id]);

  await call(ctx.app, 'PATCH', `/v1/admin/points/${p.id}`, { token: mod.token, body: { status: 'active' } });
  const detail = await call(ctx.app, 'GET', `/v1/admin/points/${p.id}`, { token: mod.token });
  assert.equal(detail.body.point.status, 'active');
  assert.equal(detail.body.history.length, 2);
});

test('ban a driver and hide their points; unban', async () => {
  const mod = await staff(ctx, 'moderator');
  const bad = await registered(ctx.app);
  await addPoint(ctx.app, bad.token);
  await addPoint(ctx.app, bad.token, { type: 'bump' });
  const viewer = await anonymous(ctx.app);

  const ban = await call(ctx.app, 'POST', `/v1/admin/users/${bad.id}/ban`, {
    token: mod.token,
    body: { reason: 'fake cameras', hidePoints: true },
  });
  assert.equal(ban.status, 200);
  assert.equal(ban.body.hiddenPoints, 2);
  assert.equal(ban.body.user.status, 'banned');
  // Signed out everywhere, and can't sign back in.
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token: bad.token })).status, 401);
  const login = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email: bad.email, password: 'correct horse' } });
  assert.equal(login.body.error.code, 'banned');
  assert.deepEqual((await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: viewer })).body.points, []);

  const unban = await call(ctx.app, 'POST', `/v1/admin/users/${bad.id}/unban`, { token: mod.token });
  assert.equal(unban.body.user.status, 'active');
  const relogin = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email: bad.email, password: 'correct horse' } });
  assert.equal(relogin.status, 200);
});

test('moderators cannot act on staff or themselves; admins set roles', async () => {
  const mod = await staff(ctx, 'moderator');
  const admin = await staff(ctx, 'admin');
  const banAdmin = await call(ctx.app, 'POST', `/v1/admin/users/${admin.id}/ban`, { token: mod.token, body: {} });
  assert.equal(banAdmin.status, 403);
  const banSelf = await call(ctx.app, 'POST', `/v1/admin/users/${mod.id}/ban`, { token: mod.token, body: {} });
  assert.equal(banSelf.body.error.code, 'self');

  const driver = await registered(ctx.app);
  const byMod = await call(ctx.app, 'PATCH', `/v1/admin/users/${driver.id}`, { token: mod.token, body: { role: 'moderator' } });
  assert.equal(byMod.status, 403);
  const byAdmin = await call(ctx.app, 'PATCH', `/v1/admin/users/${driver.id}`, { token: admin.token, body: { role: 'moderator' } });
  assert.equal(byAdmin.body.user.role, 'moderator');

  const anon = await anonymous(ctx.app);
  const anonId = (await call(ctx.app, 'GET', '/v1/me', { token: anon })).body.user.id;
  const anonStaff = await call(ctx.app, 'PATCH', `/v1/admin/users/${anonId}`, { token: admin.token, body: { role: 'moderator' } });
  assert.equal(anonStaff.body.error.code, 'anonymous');
});

test('user search', async () => {
  const mod = await staff(ctx, 'moderator');
  const driver = await registered(ctx.app);
  await addPoint(ctx.app, driver.token);
  const res = await call(ctx.app, 'GET', `/v1/admin/users?q=${encodeURIComponent(driver.email)}`, { token: mod.token });
  assert.equal(res.body.users.length, 1);
  assert.equal(res.body.users[0].points, 1);
  const byId = await call(ctx.app, 'GET', `/v1/admin/users/${driver.id}`, { token: mod.token });
  assert.equal(byId.body.user.email, driver.email);
});

test('the admin panel is served with a strict content policy', async () => {
  const res = await call(ctx.app, 'GET', '/admin/');
  assert.equal(res.status, 200);
  assert.match(String(res.headers['content-type']), /text\/html/);
  assert.match(String(res.headers['content-security-policy']), /script-src 'self'/);
  assert.equal((await call(ctx.app, 'GET', '/admin')).status, 302);
});
