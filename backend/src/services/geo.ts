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
  /** OpenStreetMap: "N123" / "W45" / "R6". Google: "g:" + Google place id. */
  id: string;
  name: string;
  /** Where it is, e.g. "Duhok, Iraq". */
  address: string;
  /** null for a Google suggestion: ask GET /v1/places/:id for the spot. */
  lat: number | null;
  lng: number | null;
  /** What it is: city, town, road, mall, restaurant, fuel... */
  kind: string;
  /** Straight-line meters from the searcher, when the service says. */
  distanceM?: number | null;
}

/** One turn-by-turn instruction. */
export interface RouteStep {
  /** "Turn left onto Zakho Road". */
  instruction: string;
  /** What to do: depart, turn, fork, merge, roundabout, arrive... */
  type: string;
  /** Which way: left, slight right, straight, uturn... (may be empty). */
  modifier: string;
  /** The road to drive on after it. */
  name: string;
  /** How far / long to drive after it, until the next step. */
  distanceM: number;
  durationS: number;
  /** Where it happens. */
  lat: number;
  lng: number;
}

/** A way to drive there, from the routing service. */
export interface RawRoute {
  distanceM: number;
  durationS: number;
  /** Main roads it uses. */
  summary: string;
  /** Google "encoded polyline" format, precision 6. */
  polyline: string;
  /** Turn-by-turn directions. */
  steps: RouteStep[];
}

// ---- Turn-by-turn sentences ----------------------------------------------

const COMPASS = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'];

function ordinal(n: number): string {
  const s = n % 100 >= 11 && n % 100 <= 13 ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th';
  return `${n}${s}`;
}

function side(modifier: string): string {
  return modifier.includes('left') ? ' left' : modifier.includes('right') ? ' right' : '';
}

function turnVerb(modifier: string): string {
  switch (modifier) {
    case 'left':
    case 'right':
      return `Turn ${modifier}`;
    case 'slight left':
    case 'slight right':
      return `Bear${side(modifier)}`;
    case 'sharp left':
    case 'sharp right':
      return `Turn sharp${side(modifier)}`;
    case 'uturn':
      return 'Make a U-turn';
    case 'straight':
      return 'Go straight';
    default:
      return 'Continue';
  }
}

/** A readable sentence for an OSRM maneuver. */
export function describeStep(step: {
  type: string;
  modifier?: string;
  name?: string;
  exit?: number;
  bearingAfter?: number;
}): string {
  const mod = step.modifier ?? '';
  const name = (step.name ?? '').trim();
  const onto = name ? ` onto ${name}` : '';
  const verb = turnVerb(mod);
  switch (step.type) {
    case 'depart': {
      const b = step.bearingAfter;
      const dir = b == null ? '' : ` ${COMPASS[Math.round((((b % 360) + 360) % 360) / 45) % 8]}`;
      return `Head${dir}${name ? ` on ${name}` : ''}`;
    }
    case 'arrive':
      return mod === 'left' || mod === 'right'
        ? `Arrive at your destination, on the ${mod}`
        : 'Arrive at your destination';
    case 'turn':
      return `${verb}${onto}`;
    case 'new name':
      return name ? `Continue onto ${name}` : 'Continue';
    case 'continue':
      return mod === 'straight' || !mod ? `Continue${name ? ` on ${name}` : ''}` : `${verb}${onto}`;
    case 'merge':
      return `Merge${side(mod)}${onto}`;
    case 'on ramp':
      return `Take the ramp${side(mod)}${onto}`;
    case 'off ramp':
      return `Take the exit${side(mod)}${onto}`;
    case 'fork':
      return `Keep${side(mod) || ' straight'}${onto}`;
    case 'end of road':
      return `At the end of the road, ${verb.toLowerCase()}${onto}`;
    case 'roundabout':
    case 'rotary':
      return step.exit ? `At the roundabout, take the ${ordinal(step.exit)} exit${onto}` : `Enter the roundabout${onto}`;
    case 'roundabout turn':
      return `At the roundabout, ${verb.toLowerCase()}${onto}`;
    default:
      return `Continue${onto}`;
  }
}

interface OsrmStep {
  distance: number;
  duration: number;
  name?: string;
  ref?: string;
  maneuver: { type: string; modifier?: string; exit?: number; location: [number, number]; bearing_after?: number };
}

/** Readable steps; "exit roundabout" and notices are folded into the step before. */
export function stepsFromOsrm(steps: OsrmStep[]): RouteStep[] {
  const out: RouteStep[] = [];
  for (const s of steps) {
    const m = s.maneuver;
    const fold = m.type === 'exit roundabout' || m.type === 'exit rotary' || m.type === 'notification' || m.type === 'use lane';
    const last = out[out.length - 1];
    if (fold && last) {
      last.distanceM += Math.round(s.distance);
      last.durationS += Math.round(s.duration);
      continue;
    }
    const name = [s.name, s.ref ? `(${s.ref})` : ''].filter(Boolean).join(' ');
    out.push({
      instruction: describeStep({
        type: m.type,
        modifier: m.modifier,
        name,
        exit: m.exit,
        bearingAfter: m.bearing_after,
      }),
      type: m.type,
      modifier: m.modifier ?? '',
      name,
      distanceM: Math.round(s.distance),
      durationS: Math.round(s.duration),
      lat: m.location[1],
      lng: m.location[0],
    });
  }
  return out;
}

/** Search and routing (OpenStreetMap services by default; replaceable in tests). */
export interface GeoProvider {
  /** Near the driver first, then Iraq (the home country), then the rest of
   * the world. [session]
   * groups one search's requests (Google bills a search as one). */
  search(query: string, near: LatLng | null, lang: string, session?: string): Promise<Place[]>;
  /** The spot of a search result that came without one (Google); null if unknown. */
  place(id: string, lang: string, session?: string): Promise<Place | null>;
  routes(from: LatLng, to: LatLng): Promise<RawRoute[]>;
}

/** Search shows places in this country first. Box: [west, south, east, north]. */
export const HOME_COUNTRY = { code: 'iq', bbox: [38.79, 29.06, 48.64, 37.39] } as const;

/** The most results one search returns. */
export const MAX_RESULTS = 12;

/**
 * Joins result lists: the home country's places first (in the order found),
 * then the others; no place twice.
 */
export function homeFirst(lists: Place[][], isHome: (p: Place) => boolean, max = MAX_RESULTS): Place[] {
  const seen = new Set<string>();
  const all: Place[] = [];
  for (const list of lists) {
    for (const p of list) {
      const name = p.name.toLowerCase();
      const keys = [p.id, `${name}|${p.address.toLowerCase()}`];
      if (p.lat != null && p.lng != null) keys.push(`${name}|${p.lat.toFixed(3)}|${p.lng.toFixed(3)}`);
      if (keys.some((k) => seen.has(k))) continue;
      for (const k of keys) seen.add(k);
      all.push(p);
    }
  }
  return [...all.filter(isHome), ...all.filter((p) => !isHome(p))].slice(0, max);
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
/** Photon results as places (unnamed things without an address are skipped). */
function photonPlaces(features: PhotonFeature[]): (Place & { country: string })[] {
  const places: (Place & { country: string })[] = [];
  for (const f of features) {
    const c = f.geometry?.coordinates;
    const p = f.properties ?? {};
    if (!c || typeof c[0] !== 'number' || typeof c[1] !== 'number') continue;
    const street = [p.street, p.housenumber].filter(Boolean).join(' ');
    const name = String(p.name ?? street).trim();
    if (!name) continue;
    const parts = [street, p.district, p.city, p.county, p.state, p.country]
      .map((v) => (v == null ? '' : String(v).trim()))
      .filter((v, i, all) => v && v !== name && all.indexOf(v) === i);
    places.push({
      id: `${p.osm_type ?? 'X'}${p.osm_id ?? `${c[1]},${c[0]}`}`,
      name,
      address: parts.join(', '),
      lat: c[1],
      lng: c[0],
      kind: String(p.osm_value ?? p.type ?? 'place'),
      country: String(p.countrycode ?? '').toLowerCase(),
    });
  }
  return places;
}

/** A box about 25 km around [p]: [west, south, east, north]. (Much bigger
 * and Photon sometimes returns one fuzzy match, e.g. "mall" -> "Mal".) */
function localBox(p: LatLng): number[] {
  const d = 0.22;
  const dLng = d / Math.max(0.2, Math.cos((p.lat * Math.PI) / 180));
  return [p.lng - dLng, p.lat - d, p.lng + dLng, p.lat + d].map((n) => Number(n.toFixed(4)));
}

export function osmProvider(config: { photonUrl: string; osrmUrl: string }): GeoProvider {
  const searches = new TtlCache<Place[]>(10 * 60_000, 500);
  const routeCache = new TtlCache<RawRoute[]>(60_000, 200);

  /** One Photon search; [bbox] keeps it inside that box. */
  async function photon(query: string, near: LatLng | null, lang: string, bbox?: readonly number[]) {
    const url = new URL('/api/', config.photonUrl);
    url.searchParams.set('q', query);
    url.searchParams.set('limit', '10');
    url.searchParams.set('lang', lang);
    if (near) {
      url.searchParams.set('lat', near.lat.toFixed(5));
      url.searchParams.set('lon', near.lng.toFixed(5));
    }
    if (bbox) url.searchParams.set('bbox', bbox.join(','));
    const json = (await getJson(url.toString())) as { features?: PhotonFeature[] };
    return photonPlaces(json.features ?? []);
  }

  return {
    async search(query, near, lang) {
      const key = [query.toLowerCase(), near?.lat.toFixed(2), near?.lng.toFixed(2), lang].join('|');
      const cached = searches.get(key);
      if (cached) return cached;
      // Around the driver (~25 km), inside Iraq, and anywhere: Photon ranks
      // by name, so without the boxes "mall" finds Mosul before Duhok.
      const [local, home, world] = await Promise.allSettled([
        near ? photon(query, near, lang, localBox(near)) : Promise.resolve([]),
        photon(query, near, lang, HOME_COUNTRY.bbox),
        photon(query, near, lang),
      ]);
      if (home.status === 'rejected' && world.status === 'rejected') throw unavailable();
      const lists = [local, home, world].map((r) => (r.status === 'fulfilled' ? r.value : []));
      const nearby = new Set(lists[0]!.map((p) => p.id));
      const places = homeFirst(lists, (p) => nearby.has(p.id) || (p as Place & { country: string }).country === HOME_COUNTRY.code).map(
        ({ country: _country, ...p }: Place & { country?: string }) => p,
      );
      searches.set(key, places);
      return places;
    },

    // OpenStreetMap results always come with their spot.
    async place() {
      return null;
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
        routes?: {
          distance: number;
          duration: number;
          geometry: string;
          legs?: { summary?: string; steps?: OsrmStep[] }[];
        }[];
      };
      if (json.code === 'NoRoute' || json.code === 'NoSegment') return [];
      if (json.code !== 'Ok' || !json.routes) throw unavailable();
      const routes = json.routes.map((r) => ({
        distanceM: Math.round(r.distance),
        durationS: Math.round(r.duration),
        summary: (r.legs ?? []).map((l) => l.summary ?? '').filter(Boolean).join(', '),
        polyline: r.geometry,
        steps: stepsFromOsrm((r.legs ?? []).flatMap((l) => l.steps ?? [])),
      }));
      routeCache.set(key, routes);
      return routes;
    },
  };
}

// ---- Google Places (optional, much more complete) --------------------------

/** Google place types -> our kinds; the first that matches wins. */
const GOOGLE_KINDS: [string, string][] = [
  ['locality', 'city'],
  ['administrative_area_level_1', 'state'],
  ['administrative_area_level_2', 'county'],
  ['sublocality_level_1', 'suburb'],
  ['sublocality', 'suburb'],
  ['neighborhood', 'neighbourhood'],
  ['shopping_mall', 'mall'],
  ['supermarket', 'supermarket'],
  ['grocery_store', 'supermarket'],
  ['fast_food_restaurant', 'fast_food'],
  ['restaurant', 'restaurant'],
  ['cafe', 'cafe'],
  ['coffee_shop', 'cafe'],
  ['bakery', 'bakery'],
  ['gas_station', 'fuel'],
  ['hospital', 'hospital'],
  ['pharmacy', 'pharmacy'],
  ['doctor', 'clinic'],
  ['university', 'university'],
  ['school', 'school'],
  ['lodging', 'hotel'],
  ['mosque', 'mosque'],
  ['church', 'church'],
  ['bank', 'bank'],
  ['atm', 'bank'],
  ['park', 'park'],
  ['airport', 'airport'],
  ['car_repair', 'car_repair'],
  ['car_dealer', 'car_dealer'],
  ['gym', 'gym'],
  ['tourist_attraction', 'attraction'],
  ['store', 'shop'],
  ['route', 'road'],
  ['street_address', 'address'],
  ['premise', 'address'],
];

export function googleKind(types: string[]): string {
  const set = new Set(types);
  for (const [google, kind] of GOOGLE_KINDS) if (set.has(google)) return kind;
  for (const t of types) if (t.endsWith('_store')) return 'shop';
  return 'place';
}

interface GooglePrediction {
  placeId?: string;
  text?: { text?: string };
  structuredFormat?: { mainText?: { text?: string }; secondaryText?: { text?: string } };
  types?: string[];
  distanceMeters?: number;
}

type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

/**
 * Google Places (New): every shop, restaurant, mall, building and city in
 * the world. Set GOOGLE_PLACES_KEY to use it; without it (or when Google
 * fails) search uses OpenStreetMap. Routes always come from [fallback].
 *
 * Google's terms: results are not cached here (only place ids may be kept),
 * and the app shows "Google Maps" under them.
 */
export function googleProvider(
  config: { key: string; country?: string; url?: string; fetch?: FetchLike },
  fallback: GeoProvider,
): GeoProvider {
  const base = config.url ?? 'https://places.googleapis.com';
  const country = (config.country ?? HOME_COUNTRY.code).toLowerCase();
  const doFetch: FetchLike = config.fetch ?? ((url, init) => fetch(url, init));
  let warnedAt = 0;

  /** JSON from Google; null when Google says "no such place". */
  async function call(path: string, init: RequestInit & { fieldMask?: string }): Promise<unknown> {
    let res: Response;
    try {
      res = await doFetch(`${base}${path}`, {
        ...init,
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': config.key,
          ...(init.fieldMask ? { 'x-goog-fieldmask': init.fieldMask } : {}),
        },
        signal: AbortSignal.timeout(8_000),
      });
    } catch {
      throw unavailable();
    }
    if (res.status === 404) return null;
    if (!res.ok) {
      // A wrong key or Places API (New) not enabled: say so in the server log
      // (at most every 10 minutes), and search falls back to OpenStreetMap.
      if (Date.now() - warnedAt > 10 * 60_000) {
        warnedAt = Date.now();
        const text = await res.text().catch(() => '');
        console.warn(`Google Places error ${res.status}: ${text.slice(0, 300)}`);
      }
      throw unavailable();
    }
    return res.json().catch(() => {
      throw unavailable();
    });
  }

  async function autocomplete(
    query: string,
    near: LatLng | null,
    lang: string,
    session: string | undefined,
    onlyHome: boolean,
  ): Promise<Place[]> {
    const center = near ? { latitude: near.lat, longitude: near.lng } : null;
    const json = (await call('/v1/places:autocomplete', {
      method: 'POST',
      body: JSON.stringify({
        input: query,
        regionCode: country,
        ...(lang === 'default' ? {} : { languageCode: lang }),
        ...(session ? { sessionToken: session } : {}),
        ...(center ? { locationBias: { circle: { center, radius: 50_000 } }, origin: center } : {}),
        ...(onlyHome ? { includedRegionCodes: [country] } : {}),
      }),
    })) as { suggestions?: { placePrediction?: GooglePrediction }[] } | null;
    const places: Place[] = [];
    for (const s of json?.suggestions ?? []) {
      const p = s.placePrediction;
      const name = (p?.structuredFormat?.mainText?.text ?? p?.text?.text ?? '').trim();
      if (!p?.placeId || !name) continue;
      places.push({
        id: `g:${p.placeId}`,
        name,
        address: (p.structuredFormat?.secondaryText?.text ?? '').trim(),
        lat: null,
        lng: null,
        kind: googleKind(p.types ?? []),
        distanceM: typeof p.distanceMeters === 'number' ? p.distanceMeters : null,
      });
    }
    return places;
  }

  return {
    async search(query, near, lang, session) {
      const [home, world] = await Promise.allSettled([
        autocomplete(query, near, lang, session, true),
        autocomplete(query, near, lang, session, false),
      ]);
      if (home.status === 'rejected' && world.status === 'rejected') {
        return fallback.search(query, near, lang, session);
      }
      const homeList = home.status === 'fulfilled' ? home.value : [];
      const homeIds = new Set(homeList.map((p) => p.id));
      const places = homeFirst([homeList, world.status === 'fulfilled' ? world.value : []], (p) => homeIds.has(p.id));
      // Nothing on Google: OpenStreetMap may still know it.
      return places.length ? places : fallback.search(query, near, lang, session);
    },

    async place(id, lang, session) {
      if (!id.startsWith('g:')) return fallback.place(id, lang, session);
      const params = new URLSearchParams();
      if (lang !== 'default') params.set('languageCode', lang);
      if (session) params.set('sessionToken', session);
      const json = (await call(`/v1/places/${encodeURIComponent(id.slice(2))}?${params}`, {
        method: 'GET',
        // Only "Essentials" fields (the cheapest); the name came with the search.
        fieldMask: 'id,location,formattedAddress,types',
      })) as {
        location?: { latitude?: number; longitude?: number };
        formattedAddress?: string;
        types?: string[];
      } | null;
      const lat = json?.location?.latitude;
      const lng = json?.location?.longitude;
      if (typeof lat !== 'number' || typeof lng !== 'number') return null;
      return {
        id,
        name: '',
        address: json?.formattedAddress ?? '',
        lat,
        lng,
        kind: googleKind(json?.types ?? []),
      };
    },

    routes: (from, to) => fallback.routes(from, to),
  };
}

/** Google Places when a key is set (OpenStreetMap as its backup), else OpenStreetMap. */
export function geoProvider(config: {
  photonUrl: string;
  osrmUrl: string;
  googlePlacesKey?: string;
  searchCountry?: string;
}): GeoProvider {
  const osm = osmProvider(config);
  return config.googlePlacesKey
    ? googleProvider({ key: config.googlePlacesKey, country: config.searchCountry }, osm)
    : osm;
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
  /** Police radar reports (mobile cameras) on this route. */
  mobiles: number;
  /** Ids (in [RoutePlan.points]) of the cameras and bumps on this route. */
  pointIds: string[];
  /** Turn-by-turn directions. */
  steps: RouteStep[];
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
        AND (p.expires_at IS NULL OR p.expires_at > CURRENT_TIMESTAMP(3))
      LIMIT 50000`,
    [user.id, box, user.id],
  );
  const byId = new Map(candidates.map((c) => [c.id, c]));
  const used = new Set<number>();
  const routes = raw.map((r, i) => {
    const on = pointsOnPath(paths[i]!, candidates);
    let cameras = 0;
    let bumps = 0;
    let mobiles = 0;
    for (const id of on) {
      used.add(id);
      const type = byId.get(id)!.type;
      if (type === 'camera') cameras++;
      else if (type === 'bump') bumps++;
      else mobiles++; // police radar reports
    }
    return {
      id: String(i),
      distanceM: r.distanceM,
      durationS: r.durationS,
      summary: r.summary,
      polyline: r.polyline,
      cameras,
      bumps,
      mobiles,
      pointIds: [...on].map(String),
      steps: r.steps ?? [],
    };
  });
  return {
    routes,
    points: [...used].map((id) => toApiPoint(byId.get(id)!, user.id)),
  };
}
