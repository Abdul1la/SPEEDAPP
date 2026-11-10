import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildApp } from '../src/app.ts';
import { select } from '../src/db.ts';
import {
  addPoint,
  anonymous,
  call,
  nearbyUrl,
  north,
  registered,
  staff,
  testConfig,
  useTestApp,
  BAGHDAD,
} from './helpers.ts';

const ctx = useTestApp();

const EPOCH = encodeURIComponent('2000-01-01T00:00:00Z');

test('a made-up Authorization header does not reset the sign-in limit', async () => {
  const app = await buildApp({ db: ctx.db, config: testConfig({ rateLimit: true }) }, false);
  try {
    let last = 0;
    for (let i = 0; i < 21; i++) {
      const res = await app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        headers: { authorization: `x${i}` },
        payload: { email: 'victim@example.com', password: `guess${i}` },
      });
      last = res.statusCode;
    }
    assert.equal(last, 429);
  } finally {
    await app.close();
  }
});

test("delta sync never reveals other drivers' private points", async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const secret = (await addPoint(ctx.app, owner, { visibility: 'private' })).body.point;
  const res = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD, `&since=${EPOCH}`), { token: other });
  assert.equal(res.status, 200);
  assert.ok(!res.body.removed.includes(secret.id));
  assert.ok(!res.body.points.some((p: { id: string }) => p.id === secret.id));
  // Owner-only answers for it look like "not found", not "not yours".
  const patch = await call(ctx.app, 'PATCH', `/v1/points/${secret.id}`, { token: other, body: { note: 'x' } });
  assert.equal(patch.status, 404);
  const del = await call(ctx.app, 'DELETE', `/v1/points/${secret.id}`, { token: other });
  assert.equal(del.status, 404);
});

test('a point made private is removed from phones that saw it', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const first = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: other });
  await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, { token: owner, body: { visibility: 'private' } });
  const since = encodeURIComponent(first.body.serverTime);
  const res = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD, `&since=${since}`), { token: other });
  assert.deepEqual(res.body.removed, [p.id]);
});

test('the owner cannot take away a point other drivers confirmed', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: other, body: { vote: 'confirm' } });

  const priv = await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, { token: owner, body: { visibility: 'private' } });
  assert.equal(priv.status, 400);
  assert.equal(priv.body.error.code, 'confirmed_by_others');
  const far = await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, { token: owner, body: north(BAGHDAD, 500) });
  assert.equal(far.body.error.code, 'confirmed_by_others');
  const near = await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, { token: owner, body: north(BAGHDAD, 40) });
  assert.equal(near.status, 200);
});

test('reports only hide a point when they outnumber its confirmations', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  for (let i = 0; i < 3; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'confirm' } });
  }
  for (let i = 0; i < 3; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'POST', `/v1/points/${p.id}/reports`, { token: t, body: { reason: 'fake' } });
  }
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner })).status, 200);
  const t = await anonymous(ctx.app);
  await call(ctx.app, 'POST', `/v1/points/${p.id}/reports`, { token: t, body: { reason: 'fake' } });
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner })).status, 404);
});

test('a point hidden by reports comes back when the reports are dismissed', async () => {
  const mod = await staff(ctx, 'moderator');
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  for (let i = 0; i < 3; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'POST', `/v1/points/${p.id}/reports`, { token: t, body: { reason: 'fake' } });
  }
  const queue = await call(ctx.app, 'GET', '/v1/admin/reports', { token: mod.token });
  assert.equal(queue.body.reports[0].point.status, 'hidden');
  for (const r of queue.body.reports) {
    await call(ctx.app, 'POST', `/v1/admin/reports/${r.id}/resolve`, { token: mod.token, body: { action: 'dismiss' } });
  }
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner })).body.point.status, 'active');
});

test('a moderator restoring a point also closes its open reports', async () => {
  const mod = await staff(ctx, 'moderator');
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const t = await anonymous(ctx.app);
  await call(ctx.app, 'POST', `/v1/points/${p.id}/reports`, { token: t, body: { reason: 'fake' } });
  await call(ctx.app, 'PATCH', `/v1/admin/points/${p.id}`, { token: mod.token, body: { status: 'hidden' } });
  const res = await call(ctx.app, 'PATCH', `/v1/admin/points/${p.id}`, { token: mod.token, body: { status: 'active' } });
  assert.equal(res.body.point.status, 'active');
  assert.equal(res.body.point.reportCount, 0);
});

test('moderator-hidden points cannot be voted on', async () => {
  const mod = await staff(ctx, 'moderator');
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner, { note: 'secret note' })).body.point;
  await call(ctx.app, 'PATCH', `/v1/admin/points/${p.id}`, { token: mod.token, body: { status: 'hidden' } });
  const t = await anonymous(ctx.app);
  const v = await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'confirm' } });
  assert.equal(v.status, 404);
});

test('adding a camera hidden by "gone" votes brings it back instead of duplicating', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  for (let i = 0; i < 3; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'gone' } });
  }
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner })).status, 404);
  for (let i = 0; i < 2; i++) {
    const t = await anonymous(ctx.app);
    const again = await addPoint(ctx.app, t, north(BAGHDAD, 5));
    assert.equal(again.body.merged, true);
    assert.equal(again.body.point.id, p.id);
  }
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner })).body.point.status, 'active');
});

test("banning a troll undoes their votes and reports", async () => {
  const mod = await staff(ctx, 'moderator');
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const troll = await registered(ctx.app);
  await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: troll.token, body: { vote: 'gone' } });
  const q = (await addPoint(ctx.app, owner, { type: 'bump' })).body.point;
  await call(ctx.app, 'POST', `/v1/points/${q.id}/reports`, { token: troll.token, body: { reason: 'fake' } });

  const ban = await call(ctx.app, 'POST', `/v1/admin/users/${troll.id}/ban`, { token: mod.token, body: { reason: 'troll' } });
  assert.equal(ban.status, 200);
  const after = await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: owner });
  assert.equal(after.body.point.goneCount, 0);
  const reports = await call(ctx.app, 'GET', '/v1/admin/reports', { token: mod.token });
  assert.equal(reports.body.reports.length, 0);
});

test('staff sign-ins expire even when the client does not ask', async () => {
  const admin = await staff(ctx, 'admin');
  const email = (await call(ctx.app, 'GET', '/v1/me', { token: admin.token })).body.user.email;
  const login = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'correct horse' } });
  assert.equal(login.status, 200);
  const rows = await select<{ expires_at: Date | null }>(
    ctx.db,
    'SELECT expires_at FROM sessions WHERE user_id = ? ORDER BY id DESC LIMIT 1',
    [Number(admin.id)],
  );
  assert.ok(rows[0]?.expires_at, 'staff session must have an expiry');
});

test('confirming again refreshes "last confirmed"', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const t = await anonymous(ctx.app);
  const first = await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'confirm' } });
  await new Promise((r) => setTimeout(r, 20));
  const second = await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'confirm' } });
  assert.ok(Date.parse(second.body.point.lastConfirmedAt) > Date.parse(first.body.point.lastConfirmedAt));
});

test('signing in with points uploaded twice leaves none without an owner', async () => {
  const account = await registered(ctx.app);
  await addPoint(ctx.app, account.token, { clientId: 'same', visibility: 'private' });
  const phone = await anonymous(ctx.app);
  await addPoint(ctx.app, phone, { clientId: 'same', visibility: 'private' });
  await addPoint(ctx.app, phone, { clientId: 'other', type: 'bump', visibility: 'private' });

  const login = await call(ctx.app, 'POST', '/v1/auth/login', {
    token: phone,
    body: { email: account.email, password: 'correct horse' },
  });
  assert.equal(login.status, 200);
  const orphans = await select<{ n: number }>(ctx.db, 'SELECT COUNT(*) AS n FROM points WHERE created_by IS NULL');
  assert.equal(orphans[0]?.n, 0);
  const mine = await call(ctx.app, 'GET', '/v1/me/points', { token: login.body.token });
  assert.deepEqual(mine.body.points.map((p: { clientId: string }) => p.clientId).sort(), ['other', 'same']);
});

test('the same upload sent twice at once creates one point', async () => {
  const token = await anonymous(ctx.app);
  const [a, b] = await Promise.all([
    addPoint(ctx.app, token, { clientId: 'twice', visibility: 'private' }),
    addPoint(ctx.app, token, { clientId: 'twice', visibility: 'private' }),
  ]);
  assert.ok(a.status < 300 && b.status < 300, `${a.status} ${b.status}`);
  assert.equal(a.body.point.id, b.body.point.id);
});

test('settings MySQL cannot store are a 400, not a server error', async () => {
  const token = await anonymous(ctx.app);
  let deep: Record<string, unknown> = {};
  for (let i = 0; i < 120; i++) deep = { d: deep };
  const res = await call(ctx.app, 'PUT', '/v1/me/settings', { token, body: { settings: deep } });
  assert.equal(res.status, 400);
});
