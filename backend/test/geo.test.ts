import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { FastifyInstance } from 'fastify';

import { buildApp } from '../src/app.ts';
import { ApiError } from '../src/lib/errors.ts';
import { decodePolyline, osmProvider } from '../src/services/geo.ts';
import type { GeoProvider, LatLng, Place, RawRoute } from '../src/services/geo.ts';
import { addPoint, anonymous, call, testConfig, useTestApp } from './helpers.ts';

const ctx = useTestApp();

/** Encodes [lat, lng] pairs as a Google polyline (the inverse of decodePolyline). */
function encode(path: [number, number][], precision = 6): string {
  const factor = 10 ** precision;
  let out = '';
  let pLat = 0;
  let pLng = 0;
  const put = (v: number) => {
    let n = v < 0 ? ~(v << 1) : v << 1;
    while (n >= 0x20) {
      out += String.fromCharCode((0x20 | (n & 0x1f)) + 63);
      n >>= 5;
    }
    out += String.fromCharCode(n + 63);
  };
  for (const [lat, lng] of path) {
    const la = Math.round(lat * factor);
    const ln = Math.round(lng * factor);
    put(la - pLat);
    put(ln - pLng);
    pLat = la;
    pLng = ln;
  }
  return out;
}

const DUHOK: LatLng = { lat: 36.8669, lng: 42.9885 };
const m = (meters: number) => meters / 111_320; // north, in degrees of latitude

// Route A goes straight north 2 km; route B goes east 1 km, then north.
const routeA: [number, number][] = [
  [DUHOK.lat, DUHOK.lng],
  [DUHOK.lat + m(2000), DUHOK.lng],
];
const eastLng = DUHOK.lng + 1000 / (111_320 * Math.cos((DUHOK.lat * Math.PI) / 180));
const routeB: [number, number][] = [
  [DUHOK.lat, DUHOK.lng],
  [DUHOK.lat, eastLng],
  [DUHOK.lat + m(2000), eastLng],
];

function fakeGeo(overrides: Partial<GeoProvider> = {}) {
  const calls: { query?: string; near?: LatLng | null; lang?: string } = {};
  const geo: GeoProvider = {
    async search(query, near, lang): Promise<Place[]> {
      Object.assign(calls, { query, near, lang });
      return [{ id: 'R1', name: 'Duhok', address: 'Duhok, Iraq', lat: 36.85, lng: 42.99, kind: 'city' }];
    },
    async routes(): Promise<RawRoute[]> {
      return [
        { distanceM: 2000, durationS: 180, summary: 'Zakho Road', polyline: encode(routeA) },
        { distanceM: 3000, durationS: 260, summary: 'Ring Road', polyline: encode(routeB) },
      ];
    },
    ...overrides,
  };
  return { geo, calls };
}

async function appWith(geo: GeoProvider): Promise<FastifyInstance> {
  return buildApp({ db: ctx.db, config: testConfig(), geo }, false);
}

test('decodes Google polylines', () => {
  // The example from Google's documentation (precision 5).
  assert.deepEqual(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', 5), [
    [38.5, -120.2],
    [40.7, -120.95],
    [43.252, -126.453],
  ]);
  assert.deepEqual(decodePolyline(encode(routeB)), routeB.map(([a, b]) => [Number(a.toFixed(6)), Number(b.toFixed(6))]));
});

test('place search needs a sign-in and passes the place to search near', async () => {
  const { geo, calls } = fakeGeo();
  const app = await appWith(geo);
  try {
    assert.equal((await call(app, 'GET', '/v1/places?q=duhok')).status, 401);
    const token = await anonymous(app);
    const res = await call(app, 'GET', '/v1/places?q=%20duhok%20&lat=36.8&lng=42.9&lang=default', { token });
    assert.equal(res.status, 200);
    assert.equal(res.body.places[0].name, 'Duhok');
    assert.deepEqual(calls, { query: 'duhok', near: { lat: 36.8, lng: 42.9 }, lang: 'default' });
    assert.equal((await call(app, 'GET', '/v1/places?q=', { token })).status, 400);
  } finally {
    await app.close();
  }
});

test('routes list the cameras and bumps on each way, in its direction', async () => {
  const { geo } = fakeGeo();
  const app = await appWith(geo);
  try {
    const me = await anonymous(app);
    const other = await anonymous(app);
    const at = (lat: number, lng: number) => ({ lat, lng });
    // On route A, northbound: counted.
    const camA = await addPoint(app, other, { ...at(DUHOK.lat + m(500), DUHOK.lng + 0.0001), direction: 0 });
    // On route A but for the other direction: not counted.
    await addPoint(app, other, { ...at(DUHOK.lat + m(900), DUHOK.lng), direction: 180, type: 'camera' });
    // 200 m beside route A: not on it.
    await addPoint(app, other, { ...at(DUHOK.lat + m(1200), DUHOK.lng + 0.0025), type: 'bump' });
    // Another driver's private point on route A: never shown.
    await addPoint(app, other, { ...at(DUHOK.lat + m(1500), DUHOK.lng), type: 'bump', visibility: 'private' });
    // My own private bump on route A: counted (it's mine).
    const mineA = await addPoint(app, me, { ...at(DUHOK.lat + m(1800), DUHOK.lng), type: 'bump', visibility: 'private' });
    // On route B's first leg (both ways): counted for B only.
    const bumpB = await addPoint(app, other, { ...at(DUHOK.lat, DUHOK.lng + 0.005), type: 'bump' });

    const res = await call(app, 'GET', `/v1/routes?from=${DUHOK.lat},${DUHOK.lng}&to=${DUHOK.lat + m(2000)},${DUHOK.lng}`, {
      token: me,
    });
    assert.equal(res.status, 200);
    const [a, b] = res.body.routes;
    assert.equal(a.summary, 'Zakho Road');
    assert.equal(a.cameras, 1);
    assert.equal(a.bumps, 1);
    assert.deepEqual(a.pointIds.sort(), [camA.body.point.id, mineA.body.point.id].sort());
    assert.equal(b.cameras, 0);
    assert.deepEqual(b.pointIds, [bumpB.body.point.id]);
    assert.deepEqual(
      res.body.points.map((p: { id: string }) => p.id).sort(),
      [camA.body.point.id, mineA.body.point.id, bumpB.body.point.id].sort(),
    );
    assert.equal(typeof a.polyline, 'string');
  } finally {
    await app.close();
  }
});

test('routes: bad input, no route, service down', async () => {
  const token = await anonymous(ctx.app);
  assert.equal((await call(ctx.app, 'GET', '/v1/routes?from=abc&to=1,2', { token })).status, 400);

  const none = await appWith(fakeGeo({ routes: async () => [] }).geo);
  const down = await appWith(
    fakeGeo({
      routes: async () => {
        throw new ApiError(502, 'geo_unavailable', 'down');
      },
    }).geo,
  );
  try {
    const t1 = await anonymous(none);
    const r1 = await call(none, 'GET', '/v1/routes?from=36.8,42.9&to=37.1,42.6', { token: t1 });
    assert.equal(r1.status, 404);
    assert.equal(r1.body.error.code, 'no_route');
    const t2 = await anonymous(down);
    const r2 = await call(down, 'GET', '/v1/routes?from=36.8,42.9&to=37.1,42.6', { token: t2 });
    assert.equal(r2.status, 502);
    assert.equal(r2.body.error.code, 'geo_unavailable');
  } finally {
    await none.close();
    await down.close();
  }
});

test('OpenStreetMap services unreachable: a clear 502, not a crash', async () => {
  const geo = osmProvider({ photonUrl: 'http://127.0.0.1:9', osrmUrl: 'http://127.0.0.1:9' });
  await assert.rejects(geo.search('duhok', null, 'en'), (e: unknown) => (e as ApiError).code === 'geo_unavailable');
  await assert.rejects(geo.routes(DUHOK, DUHOK), (e: unknown) => (e as ApiError).code === 'geo_unavailable');
});

test('live OpenStreetMap services (set GEO_LIVE=1)', { skip: !process.env.GEO_LIVE }, async () => {
  const geo = osmProvider({ photonUrl: 'https://photon.komoot.io', osrmUrl: 'https://router.project-osrm.org' });
  const places = await geo.search('Duhok', { lat: 36.86, lng: 42.99 }, 'en');
  assert.ok(places.some((p) => p.name === 'Duhok' && p.kind === 'city'), JSON.stringify(places.slice(0, 3)));
  const routes = await geo.routes({ lat: 36.8669, lng: 42.9885 }, { lat: 36.1911, lng: 44.0092 });
  assert.ok(routes.length >= 1);
  assert.ok(routes[0]!.distanceM > 100_000 && routes[0]!.summary.length > 0);
});
