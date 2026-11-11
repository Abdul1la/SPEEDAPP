import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildApp } from '../src/app.ts';
import { addPoint, anonymous, call, nearbyUrl, north, testConfig, useTestApp, BAGHDAD } from './helpers.ts';

const ctx = useTestApp();

const ids = (res: { body: { points: { id: string }[] } }) => res.body.points.map((p) => p.id).sort();

test('add a point', async () => {
  const token = await anonymous(ctx.app);
  const res = await addPoint(ctx.app, token, { clientId: 'abc', direction: 90.4, note: '  after the bridge ' });
  assert.equal(res.status, 201);
  assert.equal(res.body.created, true);
  const p = res.body.point;
  assert.equal(p.type, 'camera');
  assert.equal(p.lat, BAGHDAD.lat);
  assert.equal(p.lng, BAGHDAD.lng);
  assert.equal(p.speedLimit, 80);
  assert.equal(p.direction, 90);
  assert.equal(p.note, 'after the bridge');
  assert.equal(p.visibility, 'public');
  assert.equal(p.mine, true);
  assert.equal(p.clientId, 'abc');
});

test('uploading the same point again (retry) does not duplicate it', async () => {
  const token = await anonymous(ctx.app);
  const first = await addPoint(ctx.app, token, { clientId: 'retry-me' });
  const again = await addPoint(ctx.app, token, { clientId: 'retry-me' });
  assert.equal(again.status, 200);
  assert.equal(again.body.created, false);
  assert.equal(again.body.point.id, first.body.point.id);
});

test('bad input is rejected', async () => {
  const token = await anonymous(ctx.app);
  for (const body of [{ lat: 95 }, { lng: 200 }, { type: 'tree' }, { speedLimit: 2 }, { clientId: 'has space' }]) {
    const res = await addPoint(ctx.app, token, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error.code, 'invalid_request');
  }
  // Unknown fields (e.g. from a newer app) are ignored, not an error.
  assert.equal((await addPoint(ctx.app, token, { colour: 'red' })).status, 201);
});

test('null clears a field (both ways, no limit, no note)', async () => {
  const token = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, token, { direction: 90, note: 'x' })).body.point;
  const res = await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, {
    token,
    body: { direction: null, speedLimit: null, note: null },
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.point.direction, null);
  assert.equal(res.body.point.speedLimit, null);
  assert.equal(res.body.point.note, null);
});

test('a second driver adding the same camera confirms it instead of duplicating', async () => {
  const a = await anonymous(ctx.app);
  const b = await anonymous(ctx.app);
  const first = await addPoint(ctx.app, a, { direction: 0 });
  const second = await addPoint(ctx.app, b, { ...north(BAGHDAD, 12), direction: 20 });
  assert.equal(second.status, 200);
  assert.equal(second.body.merged, true);
  assert.equal(second.body.point.id, first.body.point.id);
  assert.equal(second.body.point.mine, false);
  assert.equal(second.body.point.myVote, 'confirm');
  assert.equal(second.body.point.confirmCount, 1);
});

test('not merged: other type, other direction, farther away, or private', async () => {
  const a = await anonymous(ctx.app);
  const b = await anonymous(ctx.app);
  await addPoint(ctx.app, a, { direction: 0 });
  assert.equal((await addPoint(ctx.app, b, { type: 'bump' })).body.created, true);
  assert.equal((await addPoint(ctx.app, b, { direction: 180 })).body.created, true);
  assert.equal((await addPoint(ctx.app, b, { ...north(BAGHDAD, 60) })).body.created, true);
  assert.equal((await addPoint(ctx.app, b, { visibility: 'private' })).body.created, true);
});

test('nearby: only points inside the radius', async () => {
  const token = await anonymous(ctx.app);
  const near = await addPoint(ctx.app, token);
  const far = await addPoint(ctx.app, token, north(BAGHDAD, 8_000));
  const small = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token });
  assert.deepEqual(ids(small), [near.body.point.id]);
  const big = await call(ctx.app, 'GET', `/v1/points?lat=${BAGHDAD.lat}&lng=${BAGHDAD.lng}&radiusKm=10`, { token });
  assert.deepEqual(ids(big), [near.body.point.id, far.body.point.id].sort());
  assert.equal(big.body.truncated, false);
  assert.ok(Date.parse(big.body.serverTime));
});

test('private points are only seen by their owner', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const p = await addPoint(ctx.app, owner, { visibility: 'private' });
  assert.deepEqual(ids(await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: owner })), [p.body.point.id]);
  assert.deepEqual(ids(await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: other })), []);
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.body.point.id}`, { token: other })).status, 404);
});

test('sync with `since`: changed points, and ids to remove', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const keep = await addPoint(ctx.app, owner);
  const del = await addPoint(ctx.app, owner, { type: 'bump' });
  const hide = await addPoint(ctx.app, owner, { ...north(BAGHDAD, 200) });
  const first = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: other });
  assert.equal(first.body.points.length, 3);

  await call(ctx.app, 'PATCH', `/v1/points/${keep.body.point.id}`, { token: owner, body: { speedLimit: 60 } });
  await call(ctx.app, 'DELETE', `/v1/points/${del.body.point.id}`, { token: owner });
  await call(ctx.app, 'PATCH', `/v1/points/${hide.body.point.id}`, { token: owner, body: { visibility: 'private' } });

  const since = encodeURIComponent(first.body.serverTime);
  const changes = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD, `&since=${since}`), { token: other });
  assert.equal(changes.status, 200);
  const updated = changes.body.points.find((p: { id: string }) => p.id === keep.body.point.id);
  assert.equal(updated.speedLimit, 60);
  assert.deepEqual(changes.body.removed.sort(), [del.body.point.id, hide.body.point.id].sort());
});

test('only the owner can edit a point', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const p = await addPoint(ctx.app, owner);
  const res = await call(ctx.app, 'PATCH', `/v1/points/${p.body.point.id}`, { token: other, body: { speedLimit: 120 } });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'not_owner');
  const moved = await call(ctx.app, 'PATCH', `/v1/points/${p.body.point.id}`, {
    token: owner,
    body: { ...north(BAGHDAD, 30), direction: null },
  });
  assert.equal(moved.status, 200);
  assert.ok(Math.abs(moved.body.point.lat - north(BAGHDAD, 30).lat) < 1e-6);
  assert.equal(moved.body.point.direction, null);
});

test('deleting: gone if nobody confirmed it, kept for others if they did', async () => {
  const owner = await anonymous(ctx.app);
  const other = await anonymous(ctx.app);
  const lonely = await addPoint(ctx.app, owner, { type: 'bump' });
  const del1 = await call(ctx.app, 'DELETE', `/v1/points/${lonely.body.point.id}`, { token: owner });
  assert.deepEqual(del1.body, { removed: true, kept: false });
  // Deleting twice is fine (retries).
  assert.equal((await call(ctx.app, 'DELETE', `/v1/points/${lonely.body.point.id}`, { token: owner })).status, 200);

  const shared = await addPoint(ctx.app, owner);
  await call(ctx.app, 'PUT', `/v1/points/${shared.body.point.id}/vote`, { token: other, body: { vote: 'confirm' } });
  const del2 = await call(ctx.app, 'DELETE', `/v1/points/${shared.body.point.id}`, { token: owner });
  assert.deepEqual(del2.body, { removed: false, kept: true });
  const forOwner = await call(ctx.app, 'GET', `/v1/points/${shared.body.point.id}`, { token: owner });
  assert.equal(forOwner.body.point.mine, false);
  assert.equal(forOwner.body.point.myVote, 'gone');
  assert.equal(forOwner.body.point.goneCount, 1);
  const forOther = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: other });
  assert.deepEqual(ids(forOther), [shared.body.point.id]);
});

test('enough "gone" votes hide a point; confirmations bring it back', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const voters = await Promise.all(Array.from({ length: 5 }, () => anonymous(ctx.app)));
  const vote = (token: string, v: string) =>
    call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token, body: { vote: v } });

  await vote(voters[0]!, 'gone');
  const two = await vote(voters[1]!, 'gone');
  assert.equal(two.body.point.status, 'active');
  const three = await vote(voters[2]!, 'gone');
  assert.equal(three.body.point.status, 'hidden');
  assert.equal(three.body.point.goneCount, 3);
  assert.deepEqual(ids(await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: voters[4]! })), []);

  await vote(voters[3]!, 'confirm');
  const back = await vote(voters[4]!, 'confirm');
  assert.equal(back.body.point.status, 'active');
  assert.equal(back.body.point.confirmCount, 2);

  // Changing your mind is allowed.
  const removedVote = await call(ctx.app, 'DELETE', `/v1/points/${p.id}/vote`, { token: voters[4]! });
  assert.equal(removedVote.body.point.myVote, null);
  assert.equal(removedVote.body.point.confirmCount, 1);
});

test('you cannot vote on your own point', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner)).body.point;
  const v = await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: owner, body: { vote: 'confirm' } });
  assert.equal(v.body.error.code, 'own_point');
});

test('my points include private and hidden ones, not deleted ones', async () => {
  const owner = await anonymous(ctx.app);
  await addPoint(ctx.app, owner, { clientId: 'a' });
  await addPoint(ctx.app, owner, { clientId: 'b', type: 'bump', visibility: 'private' });
  const gone = await addPoint(ctx.app, owner, { clientId: 'c', ...north(BAGHDAD, 500) });
  await call(ctx.app, 'DELETE', `/v1/points/${gone.body.point.id}`, { token: owner });
  const mine = await call(ctx.app, 'GET', '/v1/me/points', { token: owner });
  assert.deepEqual(mine.body.points.map((p: { clientId: string }) => p.clientId), ['a', 'b']);
});

test('a daily limit stops floods of fake points', async () => {
  const app = await buildApp({ db: ctx.db, config: testConfig({ maxPointsPerDay: 2 }) }, false);
  try {
    const token = await anonymous(app);
    assert.equal((await addPoint(app, token)).status, 201);
    assert.equal((await addPoint(app, token, north(BAGHDAD, 500))).status, 201);
    const third = await addPoint(app, token, north(BAGHDAD, 1000));
    assert.equal(third.status, 429);
    assert.equal(third.body.error.code, 'rate_limited');
  } finally {
    await app.close();
  }
});
