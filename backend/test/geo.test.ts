import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';

import type { FastifyInstance } from 'fastify';

import { buildApp } from '../src/app.ts';
import { ApiError } from '../src/lib/errors.ts';
import {
  decodePolyline,
  describeStep,
  googleKind,
  googleProvider,
  homeFirst,
  osmProvider,
  stepsFromOsrm,
} from '../src/services/geo.ts';
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
  const calls: { query?: string; near?: LatLng | null; lang?: string; session?: string } = {};
  const geo: GeoProvider = {
    async search(query, near, lang, session): Promise<Place[]> {
      Object.assign(calls, { query, near, lang, session });
      return [{ id: 'R1', name: 'Duhok', address: 'Duhok, Iraq', lat: 36.85, lng: 42.99, kind: 'city' }];
    },
    async place(id, lang, session) {
      Object.assign(calls, { id, lang, session });
      return id === 'g:LELAV_123'
        ? { id, name: '', address: 'Nzarke, Duhok, Iraq', lat: 36.84, lng: 43.01, kind: 'neighbourhood' }
        : null;
    },
    async routes(): Promise<RawRoute[]> {
      return [
        {
          distanceM: 2000,
          durationS: 180,
          summary: 'Zakho Road',
          polyline: encode(routeA),
          steps: [
            { instruction: 'Head north on Zakho Road', type: 'depart', modifier: '', name: 'Zakho Road', distanceM: 2000, durationS: 180, lat: DUHOK.lat, lng: DUHOK.lng },
            { instruction: 'Arrive at your destination', type: 'arrive', modifier: '', name: '', distanceM: 0, durationS: 0, lat: DUHOK.lat + m(2000), lng: DUHOK.lng },
          ],
        },
        { distanceM: 3000, durationS: 260, summary: 'Ring Road', polyline: encode(routeB), steps: [] },
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
    assert.deepEqual(calls, { query: 'duhok', near: { lat: 36.8, lng: 42.9 }, lang: 'default', session: undefined });
    assert.equal(res.body.source, 'osm');
    assert.equal((await call(app, 'GET', '/v1/places?q=', { token })).status, 400);
    assert.equal((await call(app, 'GET', '/v1/places?q=duhok&session=bad%20token', { token })).status, 400);
    const withSession = await call(app, 'GET', '/v1/places?q=lelav&session=Abc_123-xyz', { token });
    assert.equal(withSession.status, 200);
    assert.equal(calls.session, 'Abc_123-xyz');
  } finally {
    await app.close();
  }
});

test('where a Google result is: GET /v1/places/:id', async () => {
  const { geo, calls } = fakeGeo();
  const app = await appWith(geo);
  try {
    assert.equal((await call(app, 'GET', '/v1/places/g:LELAV_123')).status, 401);
    const token = await anonymous(app);
    const res = await call(app, 'GET', '/v1/places/g:LELAV_123?session=Abc_123-xyz', { token });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.place, {
      id: 'g:LELAV_123',
      name: '',
      address: 'Nzarke, Duhok, Iraq',
      lat: 36.84,
      lng: 43.01,
      kind: 'neighbourhood',
    });
    assert.equal(calls.session, 'Abc_123-xyz');
    // The app sends the id URL-encoded.
    assert.equal((await call(app, 'GET', '/v1/places/g%3ALELAV_123', { token })).body.place.lat, 36.84);
    const missing = await call(app, 'GET', '/v1/places/g:NOPE_000', { token });
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error.code, 'place_not_found');
    assert.equal((await call(app, 'GET', '/v1/places/x%3Cscript%3E', { token })).status, 400);
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
    assert.deepEqual(a.steps.map((s: { instruction: string }) => s.instruction), [
      'Head north on Zakho Road',
      'Arrive at your destination',
    ]);
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
  const steps = routes[0]!.steps;
  assert.ok(steps.length > 3);
  assert.match(steps[0]!.instruction, /^Head /);
  assert.match(steps[steps.length - 1]!.instruction, /^Arrive/);
});

test('turn-by-turn sentences', () => {
  assert.equal(describeStep({ type: 'depart', name: 'Zakho Road', bearingAfter: 92 }), 'Head east on Zakho Road');
  assert.equal(describeStep({ type: 'turn', modifier: 'left', name: 'Kawa St' }), 'Turn left onto Kawa St');
  assert.equal(describeStep({ type: 'turn', modifier: 'slight right' }), 'Bear right');
  assert.equal(describeStep({ type: 'fork', modifier: 'slight left', name: 'Dishar St' }), 'Keep left onto Dishar St');
  assert.equal(describeStep({ type: 'off ramp', modifier: 'slight right' }), 'Take the exit right');
  assert.equal(describeStep({ type: 'end of road', modifier: 'right', name: 'X' }), 'At the end of the road, turn right onto X');
  assert.equal(describeStep({ type: 'roundabout', exit: 2, name: 'Zozan' }), 'At the roundabout, take the 2nd exit onto Zozan');
  assert.equal(describeStep({ type: 'arrive', modifier: 'left' }), 'Arrive at your destination, on the left');
  assert.equal(describeStep({ type: 'turn', modifier: 'uturn' }), 'Make a U-turn');
});

test('roundabout exits and notices are folded into the step before', () => {
  const at = (n: number) => ({ location: [42.99, 36.86 + n] as [number, number] });
  const steps = stepsFromOsrm([
    { distance: 54, duration: 10, name: 'Azadi', maneuver: { type: 'depart', bearing_after: 0, ...at(0) } },
    { distance: 28, duration: 5, name: 'Zozan', maneuver: { type: 'roundabout', modifier: 'right', exit: 1, ...at(1) } },
    { distance: 162, duration: 20, name: 'Zozan', maneuver: { type: 'exit roundabout', modifier: 'right', exit: 1, ...at(2) } },
    { distance: 0, duration: 0, name: 'Randi', ref: 'R1', maneuver: { type: 'arrive', ...at(3) } },
  ]);
  assert.deepEqual(
    steps.map((s) => [s.instruction, s.distanceM]),
    [
      ['Head north on Azadi', 54],
      ['At the roundabout, take the 1st exit onto Zozan', 190],
      ['Arrive at your destination', 0],
    ],
  );
  assert.equal(steps[2]!.name, 'Randi (R1)');
});

const at = (id: string, name: string, lat: number | null = 36.8, extra: Partial<Place> = {}): Place => ({
  id,
  name,
  address: '',
  lat,
  lng: lat == null ? null : 43,
  kind: 'place',
  ...extra,
});

test('Iraq first, then the rest of the world; no place twice', () => {
  const iraq = (p: Place) => p.id.startsWith('iq');
  const merged = homeFirst(
    [
      [at('iq1', 'Lelav Street'), at('tr1', 'Lelav Hotel', 37.0)],
      [at('us1', 'Lelavale', 40), at('iq1', 'Lelav Street'), at('iq2', 'Nzarke'), at('xx', 'lelav street')],
    ],
    iraq,
  );
  assert.deepEqual(
    merged.map((p) => p.id),
    ['iq1', 'iq2', 'tr1', 'us1'],
  );
  assert.equal(homeFirst([[at('a', 'A'), at('b', 'B'), at('c', 'C')]], () => false, 2).length, 2);
});

test('OpenStreetMap search: inside Iraq and anywhere, Iraq first', async () => {
  const feature = (id: number, name: string | undefined, cc: string, extra: Record<string, string> = {}) => ({
    geometry: { coordinates: [43.0, 36.85] },
    properties: { osm_type: 'N', osm_id: id, name, countrycode: cc, osm_value: 'residential', city: 'Duhok', ...extra },
  });
  const urls: URL[] = [];
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://x');
    urls.push(url);
    const bbox = url.searchParams.get('bbox');
    const features =
      bbox === '38.79,29.06,48.64,37.39' // Iraq
        ? [feature(3, 'Lelav Mall', 'IQ', { city: 'Mosul' }), feature(2, 'Lelav Street', 'IQ'), feature(9, undefined, 'IQ', { osm_value: 'school' })]
        : bbox // around the driver
          ? [feature(2, 'Lelav Street', 'IQ'), feature(4, 'Lelav Market', 'IQ', { city: 'Duhok' })]
          : [feature(1, 'Lelavale', 'US', { city: 'Hardin' }), feature(3, 'Lelav Mall', 'IQ', { city: 'Mosul' })];
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ features }));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const port = (server.address() as AddressInfo).port;
    const geo = osmProvider({ photonUrl: `http://127.0.0.1:${port}`, osrmUrl: 'http://127.0.0.1:9' });
    const places = await geo.search('lelav', DUHOK, 'en');
    // Near Duhok first, then the rest of Iraq, then the world.
    assert.deepEqual(
      places.map((p) => p.name),
      ['Lelav Street', 'Lelav Market', 'Lelav Mall', 'Lelavale'],
    );
    assert.equal(places[0]!.id, 'N2');
    assert.equal('country' in places[0]!, false);
    assert.equal(urls.length, 3);
    assert.deepEqual(urls.map((u) => u.searchParams.get('bbox')).sort(), [
      '38.79,29.06,48.64,37.39',
      '42.7135,36.6469,43.2635,37.0869',
      null,
    ].sort());
    assert.ok(urls.every((u) => u.searchParams.get('lat') === DUHOK.lat.toFixed(5)));
    // Without the driver's position: no local box.
    urls.length = 0;
    await geo.search('lelav street', null, 'en');
    assert.equal(urls.length, 2);
    assert.equal(await geo.place('N2', 'en'), null);
  } finally {
    server.close();
  }
});

/** A fake Google Places server; records each request. */
function fakeGoogle(reply: (url: string, body: any) => { status?: number; json: unknown }) {
  const requests: { url: string; body: any; headers: Record<string, string> }[] = [];
  const fetchImpl = async (url: string, init: RequestInit) => {
    const body = init.body ? JSON.parse(String(init.body)) : null;
    requests.push({ url, body, headers: init.headers as Record<string, string> });
    const r = reply(url, body);
    return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
  };
  return { fetchImpl, requests };
}

const prediction = (id: string, main: string, secondary: string, types: string[], distanceMeters?: number) => ({
  placePrediction: {
    placeId: id,
    text: { text: `${main}, ${secondary}` },
    structuredFormat: { mainText: { text: main }, secondaryText: { text: secondary } },
    types,
    ...(distanceMeters == null ? {} : { distanceMeters }),
  },
});

test('Google search: Iraq first, then the world; spot looked up when picked', async () => {
  const { fetchImpl, requests } = fakeGoogle((url, body) => {
    if (url.includes(':autocomplete')) {
      return {
        json: {
          suggestions: body.includedRegionCodes
            ? [
                prediction('LELAV_123', 'Lelav City', 'Nzarke, Duhok, Iraq', ['neighborhood', 'political'], 4200),
                prediction('MALL_1', 'Mazi Mall', 'Duhok, Iraq', ['shopping_mall', 'point_of_interest']),
              ]
            : [
                prediction('HOTEL_9', 'Lelav Hotel', 'Van, Türkiye', ['lodging']),
                prediction('LELAV_123', 'Lelav City', 'Nzarke, Duhok, Iraq', ['neighborhood']),
              ],
        },
      };
    }
    return { json: { id: 'LELAV_123', location: { latitude: 36.84, longitude: 43.01 }, formattedAddress: 'Nzarke, Duhok', types: ['neighborhood'] } };
  });
  const osm = fakeGeo().geo;
  const geo = googleProvider({ key: 'test-key', country: 'iq', fetch: fetchImpl }, osm);

  const places = await geo.search('lelav city', DUHOK, 'en', 'session_ABC123');
  assert.deepEqual(
    places.map((p) => [p.id, p.name, p.address, p.kind, p.lat, p.distanceM]),
    [
      ['g:LELAV_123', 'Lelav City', 'Nzarke, Duhok, Iraq', 'neighbourhood', null, 4200],
      ['g:MALL_1', 'Mazi Mall', 'Duhok, Iraq', 'mall', null, null],
      ['g:HOTEL_9', 'Lelav Hotel', 'Van, Türkiye', 'hotel', null, null],
    ],
  );
  const [home, world] = requests.map((r) => r.body);
  assert.deepEqual(home.includedRegionCodes, ['iq']);
  assert.equal(world.includedRegionCodes, undefined);
  for (const b of [home, world]) {
    assert.equal(b.input, 'lelav city');
    assert.equal(b.sessionToken, 'session_ABC123');
    assert.equal(b.languageCode, 'en');
    assert.deepEqual(b.locationBias.circle.center, { latitude: DUHOK.lat, longitude: DUHOK.lng });
  }
  assert.equal(requests[0]!.headers['x-goog-api-key'], 'test-key');

  const spot = await geo.place('g:LELAV_123', 'en', 'session_ABC123');
  assert.deepEqual(spot, { id: 'g:LELAV_123', name: '', address: 'Nzarke, Duhok', lat: 36.84, lng: 43.01, kind: 'neighbourhood' });
  const details = requests[2]!;
  assert.match(details.url, /\/v1\/places\/LELAV_123\?languageCode=en&sessionToken=session_ABC123$/);
  assert.equal(details.headers['x-goog-fieldmask'], 'id,location,formattedAddress,types');
  // OpenStreetMap ids go to OpenStreetMap.
  assert.equal(await geo.place('N2', 'en'), null);
});

test('Google down, key wrong, or nothing found: OpenStreetMap search instead', async () => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    const denied = fakeGoogle(() => ({ status: 403, json: { error: { status: 'PERMISSION_DENIED' } } }));
    const g1 = googleProvider({ key: 'bad', fetch: denied.fetchImpl }, fakeGeo().geo);
    assert.deepEqual((await g1.search('duhok', null, 'en')).map((p) => p.id), ['R1']);
    await assert.rejects(g1.place('g:LELAV_123', 'en'), (e: unknown) => (e as ApiError).code === 'geo_unavailable');

    const empty = fakeGoogle(() => ({ json: {} }));
    const g2 = googleProvider({ key: 'k', fetch: empty.fetchImpl }, fakeGeo().geo);
    assert.deepEqual((await g2.search('duhok', null, 'en')).map((p) => p.id), ['R1']);
    const notFound = fakeGoogle(() => ({ status: 404, json: {} }));
    const g3 = googleProvider({ key: 'k', fetch: notFound.fetchImpl }, fakeGeo().geo);
    assert.equal(await g3.place('g:GONE_1', 'en'), null);
  } finally {
    console.warn = warn;
  }
});

test('Google place types read as kinds', () => {
  assert.equal(googleKind(['shopping_mall', 'point_of_interest', 'establishment']), 'mall');
  assert.equal(googleKind(['fast_food_restaurant', 'restaurant', 'food']), 'fast_food');
  assert.equal(googleKind(['locality', 'political']), 'city');
  assert.equal(googleKind(['shoe_store', 'establishment']), 'shop');
  assert.equal(googleKind(['establishment']), 'place');
});

test('live Google Places (set GOOGLE_PLACES_KEY)', { skip: !process.env.GOOGLE_PLACES_KEY }, async () => {
  const geo = googleProvider({ key: process.env.GOOGLE_PLACES_KEY!, country: 'iq' }, fakeGeo().geo);
  const places = await geo.search('Lelav City', DUHOK, 'en');
  assert.ok(places[0]?.id.startsWith('g:'), JSON.stringify(places.slice(0, 3)));
  const spot = await geo.place(places[0]!.id, 'en');
  assert.ok(spot && Math.abs(spot.lat! - DUHOK.lat) < 1, JSON.stringify(spot));
});
