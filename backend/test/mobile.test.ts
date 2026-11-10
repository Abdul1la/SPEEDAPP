// Police radar: reported by drivers or found automatically from sudden
// slowdowns; temporary, kept accurate by "still there" / "not there".
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { execute } from '../src/db.ts';
import { RULES } from '../src/services/points.ts';
import { SLOWDOWN_RULES } from '../src/services/slowdowns.ts';
import { BAGHDAD, addPoint, anonymous, call, nearbyUrl, north, useTestApp } from './helpers.ts';

const ctx = useTestApp();

const radar = (token: string, at = BAGHDAD, body: Record<string, unknown> = {}) =>
  addPoint(ctx.app, token, { type: 'mobile', ...at, speedLimit: null, ...body });

const slowdown = (token: string, at = BAGHDAD, body: Record<string, unknown> = {}) =>
  call(ctx.app, 'POST', '/v1/slowdowns', {
    token,
    body: { ...at, heading: 0, speedBefore: 100, speedMin: 60, ...body },
  });

const minutesFromNow = (iso: string) => (new Date(iso).getTime() - Date.now()) / 60_000;

async function seen(token: string, at = BAGHDAD) {
  const res = await call(ctx.app, 'GET', nearbyUrl(at), { token });
  return res.body.points as { id: string; type: string; auto: boolean; slowdownCount: number }[];
}

// ---- Reported by a driver ---------------------------------------------------

test('a police radar report is shared, both ways, and expires', async () => {
  const a = await anonymous(ctx.app);
  const res = await radar(a, BAGHDAD, { visibility: 'private', direction: 90 });
  assert.equal(res.status, 201);
  const p = res.body.point;
  assert.equal(p.type, 'mobile');
  assert.equal(p.visibility, 'public');
  assert.equal(p.direction, null);
  assert.equal(p.auto, false);
  assert.ok(Math.abs(minutesFromNow(p.expiresAt) - RULES.mobileLifetimeMin) < 2);

  const b = await anonymous(ctx.app);
  assert.deepEqual((await seen(b)).map((x) => x.id), [p.id]);
});

test('another report within 100 m confirms it and keeps it longer', async () => {
  const a = await anonymous(ctx.app);
  const first = (await radar(a)).body.point;
  await execute(ctx.db, 'UPDATE points SET expires_at = CURRENT_TIMESTAMP(3) + INTERVAL 10 MINUTE WHERE id = ?', [
    Number(first.id),
  ]);
  const b = await anonymous(ctx.app);
  const again = await radar(b, north(BAGHDAD, 80));
  assert.equal(again.body.merged, true);
  assert.equal(again.body.point.id, first.id);
  assert.equal(again.body.point.confirmCount, 1);
  assert.ok(minutesFromNow(again.body.point.expiresAt) > RULES.mobileLifetimeMin - 2);
});

test('an expired radar leaves the map, and phones are told to remove it', async () => {
  const a = await anonymous(ctx.app);
  const b = await anonymous(ctx.app);
  const p = (await radar(a)).body.point;
  const before = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD), { token: b });
  assert.equal(before.body.points.length, 1);

  await execute(ctx.db, 'UPDATE points SET expires_at = CURRENT_TIMESTAMP(3) - INTERVAL 1 SECOND WHERE id = ?', [
    Number(p.id),
  ]);
  assert.deepEqual(await seen(b), []);
  const delta = await call(ctx.app, 'GET', nearbyUrl(BAGHDAD, `&since=${before.body.serverTime}`), { token: b });
  assert.deepEqual(delta.body.removed, [p.id]);
});

test('two "not there" after the last confirmation take it away; a new "still there" brings it back', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await radar(owner)).body.point;
  const vote = async (vote: string) => {
    const t = await anonymous(ctx.app);
    const res = await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote } });
    assert.equal(res.status, 200);
    return res.body.point;
  };
  // Confirmed by three drivers this morning...
  await vote('confirm');
  await vote('confirm');
  await vote('confirm');
  // ...gone this afternoon: two "not there" are enough.
  assert.equal((await vote('gone')).status, 'active');
  assert.equal((await vote('gone')).status, 'hidden');
  // Back again (the police came back).
  assert.equal((await vote('confirm')).status, 'active');
});

test('a fixed camera keeps the usual rules', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner, { type: 'camera' })).body.point;
  assert.equal(p.expiresAt, null);
  for (let i = 0; i < 2; i++) {
    const t = await anonymous(ctx.app);
    await call(ctx.app, 'PUT', `/v1/points/${p.id}/vote`, { token: t, body: { vote: 'gone' } });
  }
  const t = await anonymous(ctx.app);
  assert.equal((await call(ctx.app, 'GET', `/v1/points/${p.id}`, { token: t })).body.point.status, 'active');
});

test('a fixed point can\'t become a police radar', async () => {
  const owner = await anonymous(ctx.app);
  const p = (await addPoint(ctx.app, owner, { type: 'camera' })).body.point;
  const res = await call(ctx.app, 'PATCH', `/v1/points/${p.id}`, { token: owner, body: { type: 'mobile' } });
  assert.equal(res.status, 400);
});

// ---- Found automatically from slowdowns -------------------------------------

test('three drivers slowing down at the same spot put a police radar on the map', async () => {
  const drivers = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  assert.equal((await slowdown(drivers[0]!)).body.radar, null);
  assert.equal((await slowdown(drivers[1]!, north(BAGHDAD, 60))).body.radar, null);
  const third = await slowdown(drivers[2]!, north(BAGHDAD, 120));
  assert.equal(third.status, 200);
  const r = third.body.radar;
  assert.equal(r.type, 'mobile');
  assert.equal(r.auto, true);
  assert.equal(r.slowdownCount, 3);
  assert.equal(r.direction, null);

  const other = await anonymous(ctx.app);
  assert.deepEqual((await seen(other)).map((p) => [p.type, p.auto]), [['mobile', true]]);
});

test('one driver slowing down many times is not enough', async () => {
  const a = await anonymous(ctx.app);
  for (let i = 0; i < 5; i++) assert.equal((await slowdown(a)).body.radar, null);
  const b = await anonymous(ctx.app);
  assert.deepEqual(await seen(b), []);
});

test('drivers going the other way, or far away, are a different spot', async () => {
  const [a, b, c] = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  await slowdown(a);
  await slowdown(b, BAGHDAD, { heading: 180 });
  assert.equal((await slowdown(c, north(BAGHDAD, 400))).body.radar, null);
});

test('stopping (a light, a jam, a checkpoint) or gentle slowing is not counted', async () => {
  const drivers = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  for (const d of drivers) {
    assert.equal((await slowdown(d, BAGHDAD, { speedMin: 5 })).body.counted, false);
    assert.equal((await slowdown(d, BAGHDAD, { speedBefore: 80, speedMin: 70 })).body.counted, false);
  }
  assert.deepEqual(await seen(drivers[0]!), []);
});

test('slowing down at a known camera or bump is explained by it', async () => {
  const owner = await anonymous(ctx.app);
  await addPoint(ctx.app, owner, { type: 'bump', ...north(BAGHDAD, 100) });
  const drivers = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  for (const d of drivers) assert.equal((await slowdown(d)).body.counted, false);
  assert.deepEqual((await seen(owner)).map((p) => p.type), ['bump']);
});

test('a spot where drivers brake every day (a junction) is not a radar', async () => {
  const old = [await anonymous(ctx.app), await anonymous(ctx.app)];
  for (let day = 1; day <= SLOWDOWN_RULES.usualDays; day++) {
    for (const t of old) await slowdown(t);
    await execute(
      ctx.db,
      'UPDATE slowdowns SET created_at = CURRENT_TIMESTAMP(3) - INTERVAL ? DAY WHERE created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 MINUTE',
      [day],
    );
  }
  const today = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  let found = null;
  for (const t of today) found = (await slowdown(t)).body.radar;
  assert.equal(found, null);
});

test('drivers slowing down at a radar keep it on the map', async () => {
  const drivers = [await anonymous(ctx.app), await anonymous(ctx.app), await anonymous(ctx.app)];
  let r = null;
  for (const d of drivers) r = (await slowdown(d)).body.radar;
  await execute(ctx.db, 'UPDATE points SET expires_at = CURRENT_TIMESTAMP(3) + INTERVAL 5 MINUTE WHERE id = ?', [
    Number(r.id),
  ]);
  const later = await anonymous(ctx.app);
  const res = await slowdown(later, north(BAGHDAD, 50));
  assert.equal(res.body.radar.id, r.id);
  assert.equal(res.body.radar.slowdownCount, 4);
  assert.ok(minutesFromNow(res.body.radar.expiresAt) > RULES.mobileLifetimeMin - 2);
});

test('bad slowdown input is rejected', async () => {
  const a = await anonymous(ctx.app);
  for (const body of [{ lat: 95 }, { speedBefore: -1 }, { heading: 400 }, { speedMin: 'fast' }]) {
    assert.equal((await slowdown(a, BAGHDAD, body)).status, 400);
  }
});
