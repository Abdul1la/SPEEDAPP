import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildApp } from '../src/app.ts';
import { execute } from '../src/db.ts';
import { addPoint, anonymous, call, nearbyUrl, registered, testConfig, useTestApp, BAGHDAD } from './helpers.ts';

const ctx = useTestApp();

test('a new phone gets an anonymous account', async () => {
  const res = await call(ctx.app, 'POST', '/v1/auth/anonymous', { body: { deviceName: 'iPhone' } });
  assert.equal(res.status, 201);
  assert.match(res.body.token, /^sa_/);
  assert.equal(res.body.user.isAnonymous, true);

  const me = await call(ctx.app, 'GET', '/v1/me', { token: res.body.token });
  assert.equal(me.status, 200);
  assert.equal(me.body.user.id, res.body.user.id);
});

test('anonymous sign-up works without a body', async () => {
  const res = await call(ctx.app, 'POST', '/v1/auth/anonymous');
  assert.equal(res.status, 201);
});

test('requests without a valid token are refused', async () => {
  assert.equal((await call(ctx.app, 'GET', '/v1/me')).status, 401);
  const bad = await call(ctx.app, 'GET', '/v1/me', { token: 'sa_nope' });
  assert.equal(bad.status, 401);
  assert.equal(bad.body.error.code, 'unauthorized');
});

test('registering keeps the anonymous account and its points', async () => {
  const token = await anonymous(ctx.app);
  const before = await call(ctx.app, 'GET', '/v1/me', { token });
  await addPoint(ctx.app, token, { clientId: 'local-1' });

  const reg = await call(ctx.app, 'POST', '/v1/auth/register', {
    token,
    body: { email: 'Me@Example.com', password: 'long enough', displayName: 'Ahmed' },
  });
  assert.equal(reg.status, 201);
  assert.equal(reg.body.user.id, before.body.user.id);
  assert.equal(reg.body.user.email, 'me@example.com');
  assert.equal(reg.body.user.isAnonymous, false);

  const mine = await call(ctx.app, 'GET', '/v1/me/points', { token: reg.body.token });
  assert.equal(mine.body.points.length, 1);
  assert.equal(mine.body.points[0].clientId, 'local-1');
});

test('register checks email and password', async () => {
  await registered(ctx.app).then(async ({ email }) => {
    const dup = await call(ctx.app, 'POST', '/v1/auth/register', { body: { email: email.toUpperCase(), password: 'long enough' } });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.error.code, 'email_taken');
  });
  const weak = await call(ctx.app, 'POST', '/v1/auth/register', { body: { email: 'a@b.co', password: 'short' } });
  assert.equal(weak.body.error.code, 'weak_password');
  const badEmail = await call(ctx.app, 'POST', '/v1/auth/register', { body: { email: 'not-an-email', password: 'long enough' } });
  assert.equal(badEmail.body.error.code, 'invalid_email');
});

test('login: wrong password and unknown email get the same answer', async () => {
  const { email } = await registered(ctx.app);
  const wrong = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'wrong password' } });
  const unknown = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email: 'nobody@example.com', password: 'x' } });
  assert.equal(wrong.status, 401);
  assert.equal(unknown.status, 401);
  assert.equal(wrong.body.error.code, 'invalid_login');
  assert.deepEqual(wrong.body, unknown.body);

  const ok = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'correct horse' } });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.merged, 0);
});

test('signing in on a phone moves its anonymous points into the account', async () => {
  const account = await registered(ctx.app);
  const phone = await anonymous(ctx.app);
  await addPoint(ctx.app, phone, { clientId: 'p1' });
  await addPoint(ctx.app, phone, { clientId: 'p2', type: 'bump', visibility: 'private' });

  const login = await call(ctx.app, 'POST', '/v1/auth/login', {
    token: phone,
    body: { email: account.email, password: 'correct horse' },
  });
  assert.equal(login.status, 200);
  assert.equal(login.body.merged, 2);

  const mine = await call(ctx.app, 'GET', '/v1/me/points', { token: login.body.token });
  assert.deepEqual(mine.body.points.map((p: { clientId: string }) => p.clientId).sort(), ['p1', 'p2']);
  // The anonymous account is gone.
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token: phone })).status, 401);
});

test('logout signs out only that phone', async () => {
  const { token, email } = await registered(ctx.app);
  const other = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'correct horse' } });
  assert.equal((await call(ctx.app, 'POST', '/v1/auth/logout', { token })).status, 204);
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token })).status, 401);
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token: other.body.token })).status, 200);
});

test('changing the password signs out the other phones', async () => {
  const { token, email } = await registered(ctx.app);
  const other = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'correct horse' } });
  const res = await call(ctx.app, 'POST', '/v1/auth/password', {
    token,
    body: { currentPassword: 'correct horse', newPassword: 'battery staple' },
  });
  assert.equal(res.status, 204);
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token })).status, 200);
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token: other.body.token })).status, 401);
  const login = await call(ctx.app, 'POST', '/v1/auth/login', { body: { email, password: 'battery staple' } });
  assert.equal(login.status, 200);
});

test('settings backup: save and restore', async () => {
  const token = await anonymous(ctx.app);
  const empty = await call(ctx.app, 'GET', '/v1/me/settings', { token });
  assert.deepEqual(empty.body, { settings: null, updatedAt: null });

  const settings = { cameraDistances: [500, 300], repeats: { camera: 2 }, muted: false };
  const put = await call(ctx.app, 'PUT', '/v1/me/settings', { token, body: { settings } });
  assert.equal(put.status, 200);
  const got = await call(ctx.app, 'GET', '/v1/me/settings', { token });
  assert.deepEqual(got.body.settings, settings);
  assert.ok(got.body.updatedAt);

  const big = await call(ctx.app, 'PUT', '/v1/me/settings', { token, body: { settings: { x: 'y'.repeat(20_000) } } });
  assert.equal(big.status, 400);
});

test('deleting the account keeps public points for other drivers', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const pub = await addPoint(ctx.app, owner);
  await addPoint(ctx.app, owner, { type: 'bump', visibility: 'private' });

  assert.equal((await call(ctx.app, 'DELETE', '/v1/me', { token: owner })).status, 204);
  assert.equal((await call(ctx.app, 'GET', '/v1/me', { token: owner })).status, 401);

  const seen = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: other });
  assert.deepEqual(seen.body.points.map((p: { id: string }) => p.id), [pub.body.point.id]);
  assert.equal(seen.body.points[0].mine, false);
});

test('a banned driver is refused', async () => {
  const { token, id } = await registered(ctx.app);
  await execute(ctx.db, "UPDATE users SET status = 'banned', ban_reason = 'fake cameras' WHERE id = ?", [Number(id)]);
  const res = await call(ctx.app, 'GET', '/v1/me', { token });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'banned');
  assert.match(res.body.error.message, /fake cameras/);
});

test('sign-up is rate limited', async () => {
  const app = await buildApp({ db: ctx.db, config: testConfig({ rateLimit: true }) }, false);
  try {
    let last = 0;
    for (let i = 0; i < 21; i++) last = (await call(app, 'POST', '/v1/auth/anonymous')).status;
    assert.equal(last, 429);
    const res = await call(app, 'POST', '/v1/auth/anonymous');
    assert.equal(res.body.error.code, 'rate_limited');
  } finally {
    await app.close();
  }
});

test('health check', async () => {
  const res = await call(ctx.app, 'GET', '/health');
  assert.deepEqual(res.body, { ok: true });
});
