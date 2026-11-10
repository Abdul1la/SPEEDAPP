// Speed cameras and speed bumps from OpenStreetMap, for the community map.
//
// Map data © OpenStreetMap contributors, under the Open Database License
// (ODbL, https://www.openstreetmap.org/copyright). Any app that shows these
// points must credit "© OpenStreetMap contributors".
//
// Flow: overpassQuery() -> fetchOverpass() -> toCandidates() -> mergeNearby()
// -> planImport() (pure, decides what to add / update / remove) -> applyPlan().
import type { Db } from '../db.ts';
import { execute, select, transaction } from '../db.ts';
import type { PointStatus, PointType, StatusReason } from '../services/points.ts';
import { angleDifference, distanceMeters } from './geo.ts';

// ---- Overpass API --------------------------------------------------------

/** `traffic_calming` values that a driver feels as a bump. */
export const BUMP_KINDS = ['bump', 'hump', 'cushion', 'table', 'mini_bumps', 'speed_bump', 'speed_hump'];

/**
 * "traffic_calming=yes" (kind not given) counts as a bump on a single node:
 * in Iraq those are almost always bumps. As a way it is usually an island.
 */
const BUMP_NODE_KINDS = [...BUMP_KINDS, 'yes'];

export const OVERPASS_SERVERS = [
  'https://overpass-api.de/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

export interface OsmElement {
  type: 'node' | 'way' | 'relation';
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  /** Node ids of a way (only for the roads under cameras). */
  nodes?: number[];
  geometry?: ({ lat: number; lon: number } | null)[];
  tags?: Record<string, string>;
}

export interface OverpassData {
  elements: OsmElement[];
  remark?: string;
}

/**
 * Overpass query for one country (ISO code such as "IQ"). Two outputs:
 *  1. speed cameras, traffic cameras and bumps (`out center`, so ways come
 *     with a center point);
 *  2. the roads that speed cameras sit on (`out geom`), for the travel
 *     direction and speed limit.
 */
export function overpassQuery(country: string): string {
  if (!/^[A-Z]{2}$/.test(country)) throw new Error(`Not a country code: ${country}`);
  const calm = (kinds: string[]) => `^(${kinds.join('|')})$`;
  return `[out:json][timeout:300];
area["ISO3166-1"="${country}"][admin_level=2]->.a;
(
  node["highway"="speed_camera"](area.a);
  node["man_made"="surveillance"]["surveillance"="traffic"]["surveillance:type"="camera"](area.a);
  node["traffic_calming"~"${calm(BUMP_NODE_KINDS)}"](area.a);
  way["traffic_calming"~"${calm(BUMP_KINDS)}"](area.a);
)->.pts;
.pts out center tags;
node.pts["highway"="speed_camera"]->.cams;
way(bn.cams)["highway"];
out geom;`;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Runs [query] on the public Overpass servers, retrying with growing waits
 * when they are busy (they often are).
 */
export async function fetchOverpass(
  query: string,
  log: (m: string) => void = () => {},
  { servers = OVERPASS_SERVERS, tries = 4, firstWaitMs = 10_000 } = {},
): Promise<OverpassData> {
  let lastError = 'no servers';
  for (const server of servers) {
    let wait = firstWaitMs;
    for (let attempt = 1; attempt <= tries; attempt++) {
      try {
        const res = await fetch(server, {
          method: 'POST',
          headers: {
            'content-type': 'application/x-www-form-urlencoded',
            'user-agent': 'SpeedAlert-osm-import/1.0',
          },
          body: new URLSearchParams({ data: query }),
          signal: AbortSignal.timeout(360_000),
        });
        const text = await res.text();
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = JSON.parse(text) as OverpassData;
        // Overpass answers 200 with a "remark" when the query timed out.
        if (data.remark && /error|timeout|timed out/i.test(data.remark)) throw new Error(data.remark);
        if (!Array.isArray(data.elements)) throw new Error('No elements in the answer');
        return data;
      } catch (e) {
        lastError = `${new URL(server).host}: ${(e as Error).message}`;
        if (attempt < tries) {
          log(`  ${lastError}. Trying again in ${wait / 1000} s...`);
          await sleep(wait);
          wait *= 2;
        }
      }
    }
    log(`  ${lastError}. Trying the next server...`);
  }
  throw new Error(`Could not download from OpenStreetMap (${lastError})`);
}

// ---- OSM tags -> points --------------------------------------------------

export interface Candidate {
  /** "node/123" or "way/456". */
  key: string;
  type: PointType;
  lat: number;
  lng: number;
  speedLimit: number | null;
  /** Travel direction the point applies to (0 = north), null = both ways. */
  direction: number | null;
}

/** km/h from an OSM `maxspeed` value ("80", "50 mph"); null if unknown. */
export function parseMaxspeed(value: string | undefined): number | null {
  const m = /^\s*(\d+(?:\.\d+)?)\s*(mph|km\/h|kmh|kph)?\s*$/i.exec(value ?? '');
  if (!m) return null;
  let kmh = Number(m[1]);
  if (m[2]?.toLowerCase() === 'mph') kmh *= 1.609344;
  kmh = Math.round(kmh);
  return kmh >= 5 && kmh <= 300 ? kmh : null;
}

const COMPASS: Record<string, number> = {
  N: 0, NNE: 22.5, NE: 45, ENE: 67.5, E: 90, ESE: 112.5, SE: 135, SSE: 157.5,
  S: 180, SSW: 202.5, SW: 225, WSW: 247.5, W: 270, WNW: 292.5, NW: 315, NNW: 337.5,
};

/** Degrees from an OSM `direction` value ("90", "NE"); null for anything else. */
export function parseCompass(value: string | undefined): number | null {
  const s = (value ?? '').trim().toUpperCase();
  if (/^\d+(\.\d+)?$/.test(s)) {
    const n = Number(s);
    return n <= 360 ? n % 360 : null;
  }
  return COMPASS[s] ?? null;
}

/** Compass bearing from a to b, 0..360. */
export function bearing(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const r = Math.PI / 180;
  const y = Math.sin((b.lon - a.lon) * r) * Math.cos(b.lat * r);
  const x =
    Math.cos(a.lat * r) * Math.sin(b.lat * r) -
    Math.sin(a.lat * r) * Math.cos(b.lat * r) * Math.cos((b.lon - a.lon) * r);
  return ((Math.atan2(y, x) / r) % 360 + 360) % 360;
}

const norm = (deg: number) => ((Math.round(deg) % 360) + 360) % 360;

interface RoadAt {
  road: OsmElement;
  /** Index of the camera's node in the road. */
  index: number;
}

/** 1 = traffic goes the way the road is drawn, -1 = the other way, 0 = both. */
function onewayFlow(road: OsmElement): 1 | -1 | 0 {
  const v = road.tags?.oneway;
  if (v === 'yes' || v === 'true' || v === '1') return 1;
  if (v === '-1' || v === 'reverse') return -1;
  if (v == null && (road.tags?.junction === 'roundabout' || road.tags?.highway === 'motorway')) return 1;
  return 0;
}

/** Direction the road is drawn in at this node (from its neighbours). */
function roadBearing({ road, index }: RoadAt): number | null {
  const g = road.geometry ?? [];
  const a = g[Math.max(index - 1, 0)];
  const b = g[Math.min(index + 1, g.length - 1)];
  if (!a || !b || a === b) return null;
  return bearing(a, b);
}

/**
 * What a numeric `direction` on a camera means in this data: "facing" (the
 * way the camera looks, so traffic drives the opposite way) or "travel".
 * Decided by the cameras on one-way roads, where the real travel direction is
 * known. In Iraq (checked 2026-11) 239 of 246 such cameras use "facing".
 */
export type DirectionMeaning = 'facing' | 'travel';

export interface Convention {
  meaning: DirectionMeaning;
  facing: number;
  travel: number;
}

export function detectConvention(cameras: OsmElement[], roadsAt: Map<number, RoadAt[]>): Convention {
  let facing = 0;
  let travel = 0;
  for (const cam of cameras) {
    const tagged = parseCompass(cam.tags?.direction);
    if (tagged == null) continue;
    for (const at of roadsAt.get(cam.id) ?? []) {
      const flow = onewayFlow(at.road);
      const drawn = roadBearing(at);
      if (!flow || drawn == null) continue;
      const diff = angleDifference(tagged, flow === 1 ? drawn : drawn + 180);
      if (diff <= 45) travel++;
      else if (diff >= 135) facing++;
      break;
    }
  }
  // No evidence: "facing" is what OSM mappers use most.
  return { meaning: travel > facing ? 'travel' : 'facing', facing, travel };
}

function cameraDirection(cam: OsmElement, roads: RoadAt[], meaning: DirectionMeaning): number | null {
  // 1. On a one-way road: the way its traffic flows.
  for (const at of roads) {
    const flow = onewayFlow(at.road);
    const drawn = roadBearing(at);
    if (flow && drawn != null) return norm(flow === 1 ? drawn : drawn + 180);
  }
  const tag = cam.tags?.direction ?? cam.tags?.['camera:direction'];
  // 2. "forward" / "backward": along the road it sits on.
  if (tag === 'forward' || tag === 'backward') {
    for (const at of roads) {
      const drawn = roadBearing(at);
      if (drawn != null) return norm(tag === 'forward' ? drawn : drawn + 180);
    }
    return null;
  }
  // 3. A compass direction.
  const deg = parseCompass(tag);
  if (deg == null) return null;
  return norm(meaning === 'facing' ? deg + 180 : deg);
}

function roadSpeedLimit(roads: RoadAt[]): number | null {
  for (const { road } of roads) {
    const kmh = parseMaxspeed(road.tags?.maxspeed);
    if (kmh != null) return kmh;
  }
  return null;
}

/** A traffic camera on a pole ("man_made=surveillance", "surveillance=traffic"). */
function isTrafficCamera(el: OsmElement): boolean {
  const t = el.tags ?? {};
  return (
    el.type === 'node' &&
    t.man_made === 'surveillance' &&
    t.surveillance === 'traffic' &&
    t['surveillance:type'] === 'camera'
  );
}

/** Turns Overpass data (see [overpassQuery]) into points. */
export function toCandidates(data: OverpassData): { candidates: Candidate[]; convention: Convention } {
  const roadsAt = new Map<number, RoadAt[]>();
  const points: OsmElement[] = [];
  for (const el of data.elements) {
    if (el.type === 'way' && el.nodes && el.geometry) {
      el.nodes.forEach((nodeId, index) => {
        const list = roadsAt.get(nodeId) ?? [];
        list.push({ road: el, index });
        roadsAt.set(nodeId, list);
      });
    } else {
      points.push(el);
    }
  }

  const isCamera = (el: OsmElement) => el.type === 'node' && el.tags?.highway === 'speed_camera';
  const convention = detectConvention(points.filter(isCamera), roadsAt);

  const candidates: Candidate[] = [];
  const seen = new Set<string>();
  for (const el of points) {
    const key = `${el.type}/${el.id}`;
    const lat = el.lat ?? el.center?.lat;
    const lng = el.lon ?? el.center?.lon;
    if (seen.has(key) || lat == null || lng == null) continue;
    const tags = el.tags ?? {};
    if (tags.disused === 'yes' || tags.abandoned === 'yes') continue;
    seen.add(key);
    if (isCamera(el)) {
      const roads = roadsAt.get(el.id) ?? [];
      candidates.push({
        key,
        type: 'camera',
        lat: round6(lat),
        lng: round6(lng),
        speedLimit: parseMaxspeed(tags.maxspeed) ?? roadSpeedLimit(roads),
        direction: cameraDirection(el, roads, convention.meaning),
      });
    } else if (isTrafficCamera(el)) {
      // A road-watching camera (not tagged as a speed camera): warn both ways.
      candidates.push({ key, type: 'camera', lat: round6(lat), lng: round6(lng), speedLimit: parseMaxspeed(tags.maxspeed), direction: null });
    } else if ((el.type === 'node' ? BUMP_NODE_KINDS : BUMP_KINDS).includes(tags.traffic_calming ?? '')) {
      candidates.push({ key, type: 'bump', lat: round6(lat), lng: round6(lng), speedLimit: null, direction: null });
    }
  }
  return { candidates, convention };
}

/** Same as the database column: DECIMAL(9, 6). */
export function round6(n: number): number {
  return Math.round(n * 1e6) / 1e6;
}

// ---- Same place? ---------------------------------------------------------

/** Same rule as the app's "is this the same point" (see RULES in points.ts). */
export const MERGE_RADIUS_M = 25;
export const MERGE_ANGLE = 45;

interface Placed {
  type: PointType;
  lat: number;
  lng: number;
  direction: number | null;
}

export function samePlace(a: Placed, b: Placed): boolean {
  return (
    a.type === b.type &&
    distanceMeters(a.lat, a.lng, b.lat, b.lng) <= MERGE_RADIUS_M &&
    (a.direction == null || b.direction == null || angleDifference(a.direction, b.direction) <= MERGE_ANGLE)
  );
}

/**
 * Finds points near a place quickly. Cells are 0.001° (about 110 m by 90 m
 * in Iraq), larger than [MERGE_RADIUS_M] up to about 75° latitude, so the
 * 3 x 3 cells around a place hold everything that can match.
 */
export class PlaceIndex<T extends Placed> {
  private readonly cells = new Map<string, T[]>();

  private static cell(lat: number, lng: number, dLat = 0, dLng = 0): string {
    return `${Math.floor(lat * 1000) + dLat}:${Math.floor(lng * 1000) + dLng}`;
  }

  add(item: T): void {
    const k = PlaceIndex.cell(item.lat, item.lng);
    const list = this.cells.get(k);
    if (list) list.push(item);
    else this.cells.set(k, [item]);
  }

  remove(item: T): void {
    const list = this.cells.get(PlaceIndex.cell(item.lat, item.lng));
    const i = list?.indexOf(item) ?? -1;
    if (i >= 0) list!.splice(i, 1);
  }

  /** First item at the same place as [p] (see [samePlace]). */
  find(p: Placed, where: (item: T) => boolean = () => true): T | undefined {
    for (let dLat = -1; dLat <= 1; dLat++) {
      for (let dLng = -1; dLng <= 1; dLng++) {
        for (const item of this.cells.get(PlaceIndex.cell(p.lat, p.lng, dLat, dLng)) ?? []) {
          if (samePlace(p, item) && where(item)) return item;
        }
      }
    }
    return undefined;
  }
}

/**
 * Drops points mapped twice in OSM (same type within 25 m, same way). The
 * one kept takes the other's speed limit if it has none.
 */
export function mergeNearby(candidates: Candidate[]): { kept: Candidate[]; merged: number } {
  const index = new PlaceIndex<Candidate>();
  const kept: Candidate[] = [];
  let merged = 0;
  for (const c of candidates) {
    const twin = index.find(c);
    if (twin) {
      twin.speedLimit ??= c.speedLimit;
      merged++;
    } else {
      const copy = { ...c };
      index.add(copy);
      kept.push(copy);
    }
  }
  return { kept, merged };
}

// ---- Database ------------------------------------------------------------

/** client_id of an imported point, e.g. "osm:IQ:node/123". */
export function importClientId(country: string, key: string): string {
  return `osm:${country}:${key}`;
}

export interface ImportedRow {
  id: number;
  type: PointType;
  lat: number;
  lng: number;
  speed_limit: number | null;
  direction: number | null;
  status: PointStatus;
  status_reason: StatusReason | null;
  client_id: string;
}

export interface OtherRow {
  type: PointType;
  lat: number;
  lng: number;
  direction: number | null;
}

export interface PlanUpdate {
  id: number;
  clientId: string;
  point: Candidate;
  /** It was removed by an earlier --prune and is back in OSM. */
  restore: boolean;
}

export interface ImportPlan {
  insert: { clientId: string; point: Candidate }[];
  update: PlanUpdate[];
  /** Ids of imported points that are no longer in OSM. */
  remove: number[];
  unchanged: number;
  /** Already on the map, added by a driver or an admin. */
  alreadyOnMap: number;
  /** Hidden or removed by drivers' votes, reports or a moderator: left alone. */
  keptHidden: number;
}

/** Hidden or removed by people (not by an earlier import): never undo that. */
function hiddenByPeople(row: ImportedRow): boolean {
  return row.status !== 'active' && row.status_reason != null;
}

function differs(row: ImportedRow, c: Candidate): boolean {
  return (
    row.type !== c.type ||
    round6(row.lat) !== c.lat ||
    round6(row.lng) !== c.lng ||
    row.speed_limit !== c.speedLimit ||
    row.direction !== c.direction
  );
}

/**
 * Decides what the import changes, without touching the database:
 *  * a point imported before (same OSM id) is updated if OSM changed it;
 *  * a new OSM point at the place of an old imported one that left OSM
 *    (re-mapped with a new id) takes over that point;
 *  * a new OSM point where a driver already added the same point is skipped;
 *  * with [prune], imported points no longer in OSM are removed.
 * Points that drivers or moderators hid are never brought back.
 */
export function planImport(
  country: string,
  candidates: Candidate[],
  imported: ImportedRow[],
  others: OtherRow[],
  prune: boolean,
): ImportPlan {
  const plan: ImportPlan = { insert: [], update: [], remove: [], unchanged: 0, alreadyOnMap: 0, keptHidden: 0 };
  const byClientId = new Map(imported.map((r) => [r.client_id, r]));
  const wanted = new Set(candidates.map((c) => importClientId(country, c.key)));
  const used = new Set<number>();

  // Imported rows whose OSM element is gone: a new element may replace them.
  const stale = new PlaceIndex<ImportedRow>();
  for (const r of imported) if (!wanted.has(r.client_id)) stale.add(r);
  const driverPoints = new PlaceIndex<OtherRow>();
  for (const r of others) driverPoints.add(r);

  const fresh: Candidate[] = [];
  for (const c of candidates) {
    const row = byClientId.get(importClientId(country, c.key));
    if (!row) {
      fresh.push(c);
      continue;
    }
    used.add(row.id);
    if (hiddenByPeople(row)) plan.keptHidden++;
    else if (row.status !== 'active' || differs(row, c)) {
      plan.update.push({ id: row.id, clientId: row.client_id, point: c, restore: row.status !== 'active' });
    } else plan.unchanged++;
  }

  for (const c of fresh) {
    const clientId = importClientId(country, c.key);
    const old = stale.find(c, (r) => !used.has(r.id));
    if (old) {
      used.add(old.id);
      stale.remove(old);
      if (hiddenByPeople(old)) plan.keptHidden++;
      else plan.update.push({ id: old.id, clientId, point: c, restore: old.status !== 'active' });
    } else if (driverPoints.find(c)) {
      plan.alreadyOnMap++;
    } else {
      plan.insert.push({ clientId, point: c });
    }
  }

  if (prune) {
    for (const r of imported) {
      if (!used.has(r.id) && r.status === 'active') plan.remove.push(r.id);
    }
  }
  return plan;
}

/** Imported points of [country], and the drivers' points around [candidates]. */
export async function loadExisting(
  db: Db,
  country: string,
  candidates: Candidate[],
): Promise<{ imported: ImportedRow[]; others: OtherRow[] }> {
  const prefix = `${importClientId(country, '')}%`;
  const imported = await select<ImportedRow>(
    db,
    `SELECT id, type, lat, lng, speed_limit, direction, status, status_reason, client_id
       FROM points WHERE source = 'import' AND created_by IS NULL AND client_id LIKE ?`,
    [prefix],
  );
  if (candidates.length === 0) return { imported, others: [] };
  const lats = candidates.map((c) => c.lat);
  const lngs = candidates.map((c) => c.lng);
  const pad = 0.01;
  const others = await select<OtherRow>(
    db,
    `SELECT type, lat, lng, direction FROM points
      WHERE status = 'active' AND visibility = 'public'
        AND NOT (source = 'import' AND client_id LIKE ?)
        AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?`,
    [prefix, Math.min(...lats) - pad, Math.max(...lats) + pad, Math.min(...lngs) - pad, Math.max(...lngs) + pad],
  );
  return { imported, others };
}

/** Writes [plan] in one transaction. */
export async function applyPlan(db: Db, plan: ImportPlan): Promise<void> {
  await transaction(db, async (conn) => {
    for (let i = 0; i < plan.insert.length; i += 500) {
      const rows = plan.insert.slice(i, i + 500).map(({ clientId, point: p }) => [
        p.type, p.lat, p.lng, p.speedLimit, p.direction, 'public', 'active', null, clientId, 'import',
      ]);
      await execute(
        conn,
        `INSERT INTO points (type, lat, lng, speed_limit, direction, visibility, status, created_by, client_id, source)
         VALUES ?`,
        [rows],
      );
    }
    for (const { id, clientId, point: p } of plan.update) {
      await execute(
        conn,
        `UPDATE points SET type = ?, lat = ?, lng = ?, speed_limit = ?, direction = ?, client_id = ?,
                status = 'active', status_reason = NULL
          WHERE id = ?`,
        [p.type, p.lat, p.lng, p.speedLimit, p.direction, clientId, id],
      );
    }
    if (plan.remove.length) {
      // A tombstone (like any removed point), so phones delete it too.
      await execute(conn, "UPDATE points SET status = 'removed', status_reason = NULL WHERE id IN (?)", [
        plan.remove,
      ]);
    }
  });
}
