const EARTH_RADIUS_M = 6_371_000;
const METERS_PER_DEGREE_LAT = 111_320;

/** SQL that turns a WKT parameter into a lat/lng point or polygon. */
export const GEOM = "ST_GeomFromText(?, 4326, 'axis-order=long-lat')";

/** "POINT(lng lat)" for [GEOM]. */
export function pointWkt(lat: number, lng: number): string {
  return `POINT(${lng} ${lat})`;
}

/**
 * A square around a point, [radiusM] meters in every direction, as a WKT
 * polygon for [GEOM]. Used with the spatial index (MBRContains) before the
 * exact distance check.
 */
export function boxWkt(lat: number, lng: number, radiusM: number): string {
  const dLat = radiusM / METERS_PER_DEGREE_LAT;
  const cos = Math.max(Math.cos((lat * Math.PI) / 180), 0.01);
  const dLng = radiusM / (METERS_PER_DEGREE_LAT * cos);
  const minLat = Math.max(lat - dLat, -90);
  const maxLat = Math.min(lat + dLat, 90);
  const minLng = Math.max(lng - dLng, -180);
  const maxLng = Math.min(lng + dLng, 180);
  return (
    `POLYGON((${minLng} ${minLat}, ${maxLng} ${minLat}, ` +
    `${maxLng} ${maxLat}, ${minLng} ${maxLat}, ${minLng} ${minLat}))`
  );
}

/** Great-circle distance in meters. */
export function distanceMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Smallest angle between two compass directions (0..180). */
export function angleDifference(a: number, b: number): number {
  const d = Math.abs((((a - b) % 360) + 360) % 360);
  return d > 180 ? 360 - d : d;
}
