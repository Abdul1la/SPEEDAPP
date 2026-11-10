// OpenStreetMap import logic (no database needed).
import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { Candidate, ImportedRow, OsmElement } from '../src/lib/osm.ts';
import {
  importClientId,
  mergeNearby,
  overpassQuery,
  parseCompass,
  parseMaxspeed,
  planImport,
  toCandidates,
} from '../src/lib/osm.ts';

const M = 1 / 111_320; // about one meter of latitude, in degrees

test('speed limits', () => {
  assert.equal(parseMaxspeed('80'), 80);
  assert.equal(parseMaxspeed(' 60 km/h'), 60);
  assert.equal(parseMaxspeed('50 mph'), 80);
  assert.equal(parseMaxspeed('none'), null);
  assert.equal(parseMaxspeed('IQ:urban'), null);
  assert.equal(parseMaxspeed('2'), null);
  assert.equal(parseMaxspeed(undefined), null);
});

test('compass directions', () => {
  assert.equal(parseCompass('90'), 90);
  assert.equal(parseCompass('360'), 0);
  assert.equal(parseCompass('ne'), 45);
  assert.equal(parseCompass('forward'), null);
  assert.equal(parseCompass('90;270'), null);
  assert.equal(parseCompass('400'), null);
});

test('the query only accepts country codes', () => {
  assert.match(overpassQuery('IQ'), /"ISO3166-1"="IQ"/);
  assert.throws(() => overpassQuery('IQ"]; out;'));
});

/** A road drawn from south to north through node [nodeId] (in the middle). */
function roadNorth(id: number, nodeId: number, at: { lat: number; lon: number }, tags: Record<string, string>): OsmElement {
  return {
    type: 'way',
    id,
    nodes: [id * 10, nodeId, id * 10 + 1],
    geometry: [
      { lat: at.lat - 50 * M, lon: at.lon },
      at,
      { lat: at.lat + 50 * M, lon: at.lon },
    ],
    tags: { highway: 'primary', ...tags },
  };
}

const camera = (id: number, at: { lat: number; lon: number }, tags: Record<string, string> = {}): OsmElement => ({
  type: 'node',
  id,
  ...at,
  tags: { highway: 'speed_camera', ...tags },
});

test('cameras: travel direction and speed limit', () => {
  const a = { lat: 36.8, lon: 43.0 };
  const b = { lat: 36.9, lon: 43.0 };
  const c = { lat: 37.0, lon: 43.0 };
  const d = { lat: 37.1, lon: 43.0 };
  const { candidates, convention } = toCandidates({
    elements: [
      // On a one-way road going north, tagged "looks south" (facing traffic).
      camera(1, a, { direction: '180', maxspeed: '100' }),
      // Two-way road, tagged "looks west": traffic drives east.
      camera(2, b, { direction: 'W' }),
      // "forward" on a two-way road drawn north: northbound traffic. Limit from the road.
      camera(3, c, { direction: 'forward' }),
      // No direction: both ways.
      camera(4, d),
      roadNorth(10, 1, a, { oneway: 'yes' }),
      roadNorth(20, 3, c, { maxspeed: '60' }),
    ],
  });
  assert.equal(convention.meaning, 'facing');
  const byKey = new Map(candidates.map((p) => [p.key, p]));
  assert.deepEqual(byKey.get('node/1'), { key: 'node/1', type: 'camera', lat: 36.8, lng: 43, speedLimit: 100, direction: 0 });
  assert.equal(byKey.get('node/2')?.direction, 90);
  assert.equal(byKey.get('node/3')?.direction, 0);
  assert.equal(byKey.get('node/3')?.speedLimit, 60);
  assert.equal(byKey.get('node/4')?.direction, null);
  assert.equal(candidates.length, 4, 'roads are not points');
});

test('cameras: data that uses "travel" directions is read as travel', () => {
  const a = { lat: 36.8, lon: 43.0 };
  const b = { lat: 36.9, lon: 43.0 };
  const { candidates, convention } = toCandidates({
    elements: [camera(1, a, { direction: '0' }), roadNorth(10, 1, a, { oneway: 'yes' }), camera(2, b, { direction: '90' })],
  });
  assert.equal(convention.meaning, 'travel');
  assert.equal(candidates.find((p) => p.key === 'node/2')?.direction, 90);
});

test('bumps: humps, tables and ways count; islands do not', () => {
  const { candidates } = toCandidates({
    elements: [
      { type: 'node', id: 1, lat: 36.8, lon: 43, tags: { traffic_calming: 'hump' } },
      { type: 'node', id: 2, lat: 36.9, lon: 43, tags: { traffic_calming: 'island' } },
      { type: 'way', id: 3, center: { lat: 37, lon: 43 }, tags: { traffic_calming: 'table', highway: 'footway' } },
      { type: 'node', id: 4, lat: 37.1, lon: 43, tags: { traffic_calming: 'bump', disused: 'yes' } },
      // Kind not given: a bump as a node, but not as a way (usually an island).
      { type: 'node', id: 5, lat: 37.2, lon: 43, tags: { traffic_calming: 'yes' } },
      { type: 'way', id: 6, center: { lat: 37.3, lon: 43 }, tags: { traffic_calming: 'yes' } },
    ],
  });
  assert.deepEqual(
    candidates.map((p) => [p.key, p.type, p.direction]),
    [
      ['node/1', 'bump', null],
      ['way/3', 'bump', null],
      ['node/5', 'bump', null],
    ],
  );
});

test('traffic cameras on poles count as cameras, both ways; guard cameras do not', () => {
  const surveillance = (id: number, tags: Record<string, string>): OsmElement => ({
    type: 'node',
    id,
    lat: 36.8 + id / 100,
    lon: 43,
    tags: { man_made: 'surveillance', 'surveillance:type': 'camera', 'camera:direction': '60', ...tags },
  });
  const { candidates } = toCandidates({
    elements: [
      surveillance(1, { surveillance: 'traffic' }),
      surveillance(2, { surveillance: 'outdoor', 'surveillance:zone': 'parking' }),
      surveillance(3, { surveillance: 'public' }),
    ],
  });
  assert.deepEqual(
    candidates.map((p) => [p.key, p.type, p.direction, p.speedLimit]),
    [['node/1', 'camera', null, null]],
  );
});

const point = (key: string, over: Partial<Candidate> = {}): Candidate => ({
  key,
  type: 'bump',
  lat: 36.8,
  lng: 43,
  speedLimit: null,
  direction: null,
  ...over,
});

test('points mapped twice are counted once; opposite cameras are not', () => {
  const { kept, merged } = mergeNearby([
    point('node/1'),
    point('node/2', { lat: 36.8 + 10 * M }),
    point('node/3', { lat: 36.8 + 40 * M }),
    point('node/4', { type: 'camera', direction: 0 }),
    point('node/5', { type: 'camera', direction: 180, lat: 36.8 + 10 * M, speedLimit: 80 }),
    point('node/6', { type: 'camera', direction: 10, lat: 36.8 + 5 * M, speedLimit: 100 }),
  ]);
  assert.deepEqual(
    kept.map((p) => p.key),
    ['node/1', 'node/3', 'node/4', 'node/5'],
  );
  assert.equal(merged, 2);
  assert.equal(kept.find((p) => p.key === 'node/4')?.speedLimit, 100, 'takes the twin speed limit');
});

const row = (id: number, key: string, over: Partial<ImportedRow> = {}): ImportedRow => ({
  id,
  type: 'bump',
  lat: 36.8,
  lng: 43,
  speed_limit: null,
  direction: null,
  status: 'active',
  status_reason: null,
  client_id: importClientId('IQ', key),
  ...over,
});

test('import plan: add, update, keep, skip and prune', () => {
  const far = (n: number) => 36.8 + n * 0.01;
  const candidates = [
    point('node/1', { lat: far(1) }), // new
    point('node/2', { lat: far(2) }), // imported before, unchanged
    point('node/3', { lat: far(3), lng: 43.0001 }), // imported before, moved
    point('node/4', { lat: far(4) }), // hidden by votes: stays hidden
    point('node/5', { lat: far(5) }), // removed by an earlier prune, back in OSM
    point('node/6', { lat: far(6) }), // a driver already added it
    point('node/7', { lat: far(7) }), // re-mapped in OSM with a new id (old: node/70)
  ];
  const imported = [
    row(2, 'node/2', { lat: far(2) }),
    row(3, 'node/3', { lat: far(3) }),
    row(4, 'node/4', { lat: far(4), status: 'hidden', status_reason: 'votes' }),
    row(5, 'node/5', { lat: far(5), status: 'removed' }),
    row(70, 'node/70', { lat: far(7) + 5 * M }),
    row(80, 'node/80', { lat: far(8) }), // gone from OSM
    row(90, 'node/90', { lat: far(9), status: 'removed', status_reason: 'moderator' }),
  ];
  const others = [{ type: 'bump' as const, lat: far(6) + 3 * M, lng: 43, direction: null }];

  const plan = planImport('IQ', candidates, imported, others, true);
  assert.deepEqual(
    plan.insert.map((i) => i.clientId),
    ['osm:IQ:node/1'],
  );
  assert.deepEqual(
    plan.update.map((u) => [u.id, u.clientId, u.restore]),
    [
      [3, 'osm:IQ:node/3', false],
      [5, 'osm:IQ:node/5', true],
      [70, 'osm:IQ:node/7', false],
    ],
  );
  assert.deepEqual(plan.remove, [80]);
  assert.equal(plan.unchanged, 1);
  assert.equal(plan.keptHidden, 1);
  assert.equal(plan.alreadyOnMap, 1);

  const noPrune = planImport('IQ', candidates, imported, others, false);
  assert.deepEqual(noPrune.remove, []);
});
