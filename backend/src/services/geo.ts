import type { AuthUser } from '../auth/auth.ts';
import { select } from '../db.ts';
import type { Db } from '../db.ts';
import { ApiError } from '../lib/errors.ts';
import { GEOM, angleDifference } from '../lib/geo.ts';
import { POINT_COLUMNS, toApiPoint } from './points.ts';
import type { ApiPoint, PointRow } from './points.ts';

export interface LatLng {
  lat: number;
  lng: number;
}

/** A place found by search ("Duhok", a street, a shop...). */
export interface Place {
  id: string;
  name: string;
  /** Where it is, e.g. "Duhok, Iraq". */
  address: string;
  lat: number;
  lng: number;
  /** What it is (OpenStreetMap value): city, town, road, school... */
  kind: string;
}

/** A way to drive there, from the routing service. */
export interface RawRoute {
  distanceM: number;
  durationS: number;
  /** Main roads it uses. */
  summary: string;
  /** Google "encoded polyline" format, precision 6. */
  polyline: string;
}

/** Search and routing (OpenStreetMap services by default; replaceable in tests). */
export interface GeoProvider {
  search(query: string, near: LatLng | null, lang: string): Promise<Place[]>;
  routes(from: LatLng, to: LatLng): Promise<RawRoute[]>;
}

const USER_AGENT = 'SpeedAlert/1.0 (+https://github.com/Abdul1la/SPEEDAPP)';

function unavailable(): ApiError {
  return new ApiError(502, 'geo_unavailable', 'Search and directions are not available right now. Try again in a minute.');
}

async function getJson(url: string): Promise<unknown> {
  let res: Response;
  try {
    res = await fetch(url, {
      headers: { 'user-agent': USER_AGENT, accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw unavailable();
  }
  if (!res.ok && res.status !== 400) throw unavailable();
  return res.json().catch(() => {
    throw unavailable();
  });
}

/** A small time-limited cache, so popular searches don't hit the service again. */
class TtlCache<T> {
  private readonly items = new Map<string, { at: number; value: T }>();
  private readonly ttlMs: number;
  private readonly max: number;

  constructor(ttlMs: number, max: number) {
    this.ttlMs = ttlMs;
    this.max = max;
  }

  get(key: string): T | undefined {
    const hit = this.items.get(key);
    if (!hit) return undefined;
    if (Date.now() - hit.at > this.ttlMs) {
      this.items.delete(key);
      return undefined;
    }
    return hit.value;
  }

  set(key: string, value: T): void {
    if (this.items.size >= this.max) {
      const oldest = this.items.keys().next().value;
      if (oldest !== undefined) this.items.delete(oldest);
    }
    this.items.set(key, { at: Date.now(), value });
  }
}

interface PhotonFeature {
  geometry?: { coordinates?: [number, number] };
  properties?: Record<string, string | number | undefined>;
}

/**
 * OpenStreetMap services: Photon (search as you type) and OSRM (driving
 * routes with alternatives). Free, no key; fair use only. For many users,
 * point PHOTON_URL / OSRM_URL at your own servers.
 */
export function osmProvider(config: { photonUrl: string; osrmUrl: string }): GeoProvider {
  const searches = new TtlCache<Place[]>(10 * 60_000, 500);
  const routeCache = new TtlCache<RawRoute[]>(60_000, 200);

  return {
    async search(query, near, lang) {
      const key = [query.toLowerCase(), near?.lat.toFixed(2), near?.lng.toFixed(2), lang].join('|');
      const cached = searches.get(key);
      if (cached) return cached;
      const url = new URL('/api/', config.photonUrl);
      url.searchParams.set('q', query);
      url.searchParams.set('limit', '10');
      url.searchParams.set('lang', lang);
      if (near) {
        url.searchParams.set('lat', near.lat.toFixed(5));
        url.searchParams.set('lon', near.lng.toFixed(5));
      }
      const json = (await getJson(url.toString())) as { features?: PhotonFeature[] };
      const seen = new Set<string>();
      const places: Place[] = [];
      for (const f of json.features ?? []) {
        const c = f.geometry?.coordinates;
        const p = f.properties ?? {};
        if (!c || typeof c[0] !== 'number' || typeof c[1] !== 'number') continue;
        const street = [p.street, p.housenumber].filter(Boolean).join(' ');
        const name = String(p.name ?? (street || p.city || p.state || '')).trim();
        if (!name) continue;
        const parts = [street, p.district, p.city, p.county, p.state, p.country]
          .map((v) => (v == null ? '' : String(v).trim()))
          .filter((v, i, all) => v && v !== name && all.indexOf(v) === i);
        const place: Place = {
          id: `${p.osm_type ?? 'X'}${p.osm_id ?? `${c[1]},${c[0]}`}`,
          name,
          address: parts.join(', '),
          lat: c[1],
          lng: c[0],
          kind: String(p.osm_value ?? p.type ?? 'place'),
        };
        const dup = `${place.name}|${place.lat.toFixed(3)}|${place.lng.toFixed(3)}`;
        if (seen.has(dup)) continue;
        seen.add(dup);
        places.push(place);
      }
      searches.set(key, places);
      return places;
    },

    async routes(from, to) {
      const key = [from.lat, from.lng, to.lat, to.lng].map((n) => n.toFixed(4)).join('|');
      const cached = routeCache.get(key);
      if (cached) return cached;
      const coords = `${from.lng},${from.lat};${to.lng},${to.lat}`;
      const url = new URL(`/route/v1/driving/${coords}`, config.osrmUrl);
      url.searchParams.set('alternatives', '3');
      url.searchParams.set('overview', 'full');
      url.searchParams.set('geometries', 'polyline6');
      url.searchParams.set('steps', 'true'); // needed for the road names
      const json = (await getJson(url.toString())) as {
        code?: string;
        routes?: { distance: number; duration: number; geometry: string; legs?: { summary?: string }[] }[];
      };
      if (json.code === 'NoRoute' || json.code === 'NoSegment') return [];
      if (json.code !== 'Ok' || !json.routes) throw unavailable();
      const routes = json.routes.map((r) => ({
        distanceM: Math.round(r.distance),
        durationS: Math.round(r.duration),
        summary: (r.legs ?? []).map((l) => l.summary ?? '').filter(Boolean).join(', '),
        polyline: r.geometry,
      }));
      routeCache.set(key, routes);
      return routes;
    },
  };
}

// ---- Cameras and bumps along a route -------------------------------------

/** Decodes a Google "encoded polyline" into [lat, lng] pairs. */
export function decodePolyline(encoded: string, precision = 6): [number, number][] {
  const factor = 10 ** precision;
  const out: [number, number][] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  const next = () => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (index < encoded.length) {
    lat += next();
    lng += next();
    out.push([lat / factor, lng / factor]);
  }
  return out;
}

/** A point this close to the route line is on the route. */
export const ON_ROUTE_M = 35;
/** ...and its direction (if it has one) must be this close to the road's. */
const ON_ROUTE_ANGLE = 50;
const M_PER_DEG = 111_320;

function bearing(a: [number, number], b: [number, number]): number {
  const toRad = Math.PI / 180;
  const y = Math.sin((b[1] - a[1]) * toRad) * Math.cos(b[0] * toRad);
  const x =
    Math.cos(a[0] * toRad) * Math.sin(b[0] * toRad) -
    Math.sin(a[0] * toRad) * Math.cos(b[0] * toRad) * Math.cos((b[1] - a[1]) * toRad);
  return ((Math.atan2(y, x) / toRad) + 360) % 360;
}

/** Distance in meters from p to the segment a-b (flat map, fine at this size). */
function toSegment(p: [number, number], a: [number, number], b: [number, number]): number {
  const k = Math.cos((p[0] * Math.PI) / 180) * M_PER_DEG;
  const ax = (a[1] - p[1]) * k;
  const ay = (a[0] - p[0]) * M_PER_DEG;
  const bx = (b[1] - p[1]) * k;
  const by = (b[0] - p[0]) * M_PER_DEG;
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2));
  return Math.hypot(ax + t * dx, ay + t * dy);
}

/** Ids of the points that lie on [path], in its driving direction. */
export function pointsOnPath(path: [number, number][], points: PointRow[]): Set<number> {
  const found = new Set<number>();
  if (path.length < 2) return found;
  // Group the line into chunks with a bounding box, so each point is only
  // compared with the few segments near it.
  const marginLat = ON_ROUTE_M / M_PER_DEG;
  const chunks: { from: number; to: number; minLat: number; maxLat: number; minLng: number; maxLng: number }[] = [];
  for (let i = 0; i < path.length - 1; i += 32) {
    const to = Math.min(i + 32, path.length - 1);
    let minLat = Infinity;
    let maxLat = -Infinity;
    let minLng = Infinity;
    let maxLng = -Infinity;
    for (let j = i; j <= to; j++) {
      const [la, ln] = path[j]!;
      minLat = Math.min(minLat, la);
      maxLat = Math.max(maxLat, la);
      minLng = Math.min(minLng, ln);
      maxLng = Math.max(maxLng, ln);
    }
    const marginLng = marginLat / Math.max(Math.cos((minLat * Math.PI) / 180), 0.01);
    chunks.push({
      from: i,
      to,
      minLat: minLat - marginLat,
      maxLat: maxLat + marginLat,
      minLng: minLng - marginLng,
      maxLng: maxLng + marginLng,
    });
  }
  for (const pt of points) {
    const p: [number, number] = [pt.lat, pt.lng];
    search: for (const c of chunks) {
      if (p[0] < c.minLat || p[0] > c.maxLat || p[1] < c.minLng || p[1] > c.maxLng) continue;
      for (let i = c.from; i < c.to; i++) {
        const a = path[i]!;
        const b = path[i + 1]!;
        if (toSegment(p, a, b) > ON_ROUTE_M) continue;
        if (pt.direction != null && angleDifference(pt.direction, bearing(a, b)) > ON_ROUTE_ANGLE) {
          continue;
        }
        found.add(pt.id);
        break search;
      }
    }
  }
  return found;
}

export interface RouteOption {
  id: string;
  distanceM: number;
  durationS: number;
  summary: string;
  polyline: string;
  cameras: number;
  bumps: number;
  /** Ids (in [RoutePlan.points]) of the cameras and bumps on this route. */
  pointIds: string[];
}

export interface RoutePlan {
  routes: RouteOption[];
  /** Every camera and bump on any of the routes, so the phone can warn
   * about them all along the way (also far from the area it downloaded). */
  points: ApiPoint[];
}

/** Driving routes from [from] to [to], each with the cameras and bumps on it. */
export async function planRoutes(
  db: Db,
  user: AuthUser,
  provider: GeoProvider,
  from: LatLng,
  to: LatLng,
): Promise<RoutePlan> {
  const raw = await provider.routes(from, to);
  if (raw.length === 0) {
    throw new ApiError(404, 'no_route', 'No driving route was found to this place.');
  }
  const paths = raw.map((r) => decodePolyline(r.polyline));
  let minLat = Infinity;
  let maxLat = -Infinity;
  let minLng = Infinity;
  let maxLng = -Infinity;
  for (const path of paths) {
    for (const [la, ln] of path) {
      minLat = Math.min(minLat, la);
      maxLat = Math.max(maxLat, la);
      minLng = Math.min(minLng, ln);
      maxLng = Math.max(maxLng, ln);
    }
  }
  const m = 0.001; // ~100 m around the routes
  const box =
    `POLYGON((${minLng - m} ${minLat - m}, ${maxLng + m} ${minLat - m}, ` +
    `${maxLng + m} ${maxLat + m}, ${minLng - m} ${maxLat + m}, ${minLng - m} ${minLat - m}))`;
  const candidates = await select<PointRow>(
    db,
    `SELECT ${POINT_COLUMNS}, v.vote AS my_vote
       FROM points p
       LEFT JOIN point_votes v ON v.point_id = p.id AND v.user_id = ?
      WHERE MBRContains(${GEOM}, p.location)
        AND p.status = 'active' AND (p.visibility = 'public' OR p.created_by = ?)
      LIMIT 50000`,
    [user.id, box, user.id],
  );
  const byId = new Map(candidates.map((c) => [c.id, c]));
  const used = new Set<number>();
  const routes = raw.map((r, i) => {
    const on = pointsOnPath(paths[i]!, candidates);
    let cameras = 0;
    let bumps = 0;
    for (const id of on) {
      used.add(id);
      if (byId.get(id)!.type === 'camera') cameras++;
      else bumps++;
    }
    return {
      id: String(i),
      distanceM: r.distanceM,
      durationS: r.durationS,
      summary: r.summary,
      polyline: r.polyline,
      cameras,
      bumps,
      pointIds: [...on].map(String),
    };
  });
  return {
    routes,
    points: [...used].map((id) => toApiPoint(byId.get(id)!, user.id)),
  };
}
