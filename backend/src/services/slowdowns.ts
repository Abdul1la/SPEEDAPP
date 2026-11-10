// Police radar found automatically.
//
// A phone sends a "slowdown" when its driver suddenly brakes on a fast road
// without stopping, then speeds up again: the typical reaction to a police
// radar (a traffic light, a jam or a checkpoint ends in a stop, so the phone
// doesn't send those). Only that spot is sent, never the route.
//
// When enough different drivers slow down at the same spot within a short
// time, and it isn't a place where drivers brake every day (a junction, a
// bad road) or next to a known camera or bump, a police radar is put on the
// map for everyone. It expires like a reported one; drivers who slow down
// there again, or answer "still there", keep it on the map.
import type { AuthUser } from '../auth/auth.ts';
import { execute, select, selectOne, transaction } from '../db.ts';
import type { Db, Queryable } from '../db.ts';
import { tooMany } from '../lib/errors.ts';
import { GEOM, angleDifference, boxWkt, pointWkt } from '../lib/geo.ts';
import { RULES, getRow, toApiPoint } from './points.ts';
import type { ApiPoint } from './points.ts';

export const SLOWDOWN_RULES = {
  /** Slowdowns this close together are the same spot. */
  radiusM: 150,
  /** ...if the drivers went the same way (within this angle). */
  angle: 45,
  /** Slowdowns counted for a new radar: this recent. */
  windowMin: 90,
  /** Different drivers who must slow down at a spot before it is a radar. */
  minDrivers: 3,
  /** A spot where drivers slowed down on this many other days (last 14) is
   * a junction or a bad road, not a radar. */
  usualDays: 3,
  /** Braking near a known camera, bump or radar is explained by it. */
  knownPointRadiusM: 200,
  /** The phone's rule, checked again here: braking from at least... */
  minSpeedBefore: 50,
  /** ...by at least this much... */
  minDrop: 20,
  /** ...without (nearly) stopping. */
  minSpeedLowest: 15,
  /** One phone can't send more than this per hour. */
  maxPerHour: 30,
  /** Slowdowns are deleted after this many days. */
  keepDays: 14,
};

export interface SlowdownInput {
  lat: number;
  lng: number;
  heading?: number | null;
  speedBefore: number;
  speedMin: number;
}

export interface SlowdownResult {
  /** False if it was ignored (not a radar-like slowdown, or near a known point). */
  counted: boolean;
  /** The police radar it found or kept on the map, if any. */
  radar: ApiPoint | null;
}

interface Near {
  id: number;
  user_id: number;
  lat: number;
  lng: number;
  heading: number | null;
  created_at: Date;
}

const sameWay = (a: number | null | undefined, b: number | null | undefined) =>
  a == null || b == null || angleDifference(a, b) <= SLOWDOWN_RULES.angle;

export async function addSlowdown(db: Db, user: AuthUser, input: SlowdownInput): Promise<SlowdownResult> {
  const r = SLOWDOWN_RULES;
  const heading = input.heading == null ? null : ((Math.round(input.heading) % 360) + 360) % 360;
  if (
    input.speedBefore < r.minSpeedBefore ||
    input.speedBefore - input.speedMin < r.minDrop ||
    input.speedMin < r.minSpeedLowest
  ) {
    return { counted: false, radar: null };
  }

  return transaction(db, async (conn) => {
    const recent = await selectOne<{ n: number }>(
      conn,
      'SELECT COUNT(*) AS n FROM slowdowns WHERE user_id = ? AND created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 HOUR',
      [user.id],
    );
    if ((recent?.n ?? 0) >= r.maxPerHour) throw tooMany('Too many slowdowns sent. Try again later.');

    const center = pointWkt(input.lat, input.lng);
    const save = async (pointId: number | null) =>
      (
        await execute(
          conn,
          'INSERT INTO slowdowns (user_id, lat, lng, heading, speed_before, speed_min, point_id) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [user.id, input.lat, input.lng, heading, Math.round(input.speedBefore), Math.round(input.speedMin), pointId],
        )
      ).insertId;
    // Old slowdowns aren't needed (and are personal data): keep 14 days.
    await execute(conn, 'DELETE FROM slowdowns WHERE created_at < CURRENT_TIMESTAMP(3) - INTERVAL ? DAY LIMIT 500', [
      r.keepDays,
    ]);

    // 1. A police radar already here: this driver slowed down for it too,
    //    which keeps it on the map.
    const radar = await selectOne<{ id: number }>(
      conn,
      `SELECT p.id FROM points p
        WHERE p.type = 'mobile' AND p.status = 'active' AND p.visibility = 'public'
          AND (p.expires_at IS NULL OR p.expires_at > CURRENT_TIMESTAMP(3))
          AND MBRContains(${GEOM}, p.location) AND ST_Distance_Sphere(p.location, ${GEOM}) <= ?
        ORDER BY ST_Distance_Sphere(p.location, ${GEOM}) LIMIT 1 FOR UPDATE`,
      [boxWkt(input.lat, input.lng, RULES.mobileMergeRadiusM * 2), center, RULES.mobileMergeRadiusM, center],
    );
    if (radar) {
      await save(radar.id);
      await refreshAutoRadar(conn, radar.id);
      return { counted: true, radar: toApiPoint((await getRow(conn, radar.id, user.id))!, user.id) };
    }

    // 2. A known fixed camera or bump explains the braking: not saved.
    const known = await selectOne<{ id: number }>(
      conn,
      `SELECT p.id FROM points p
        WHERE p.type IN ('camera', 'bump') AND p.status = 'active' AND p.visibility = 'public'
          AND MBRContains(${GEOM}, p.location) AND ST_Distance_Sphere(p.location, ${GEOM}) <= ?
        LIMIT 1`,
      [boxWkt(input.lat, input.lng, r.knownPointRadiusM * 2), center, r.knownPointRadiusM],
    );
    if (known) return { counted: false, radar: null };
    await save(null);

    // 3. Enough different drivers slowed down here just now?
    const near = (
      await select<Near>(
        conn,
        `SELECT s.id, s.user_id, s.lat, s.lng, s.heading, s.created_at FROM slowdowns s
          WHERE s.point_id IS NULL
            AND s.created_at > CURRENT_TIMESTAMP(3) - INTERVAL ? MINUTE
            AND MBRContains(${GEOM}, s.location) AND ST_Distance_Sphere(s.location, ${GEOM}) <= ?
          FOR UPDATE`,
        [r.windowMin, boxWkt(input.lat, input.lng, r.radiusM * 2), center, r.radiusM],
      )
    ).filter((s) => sameWay(s.heading, heading));
    const drivers = new Set(near.map((s) => s.user_id));
    if (drivers.size < r.minDrivers) return { counted: true, radar: null };

    // 4. Drivers brake here every day: a junction or a bad road, not a radar.
    //    Days count when at least two drivers slowed down here, without a
    //    radar (police often come back to the same spot: those days don't
    //    count against it).
    const days = await selectOne<{ n: number }>(
      conn,
      `SELECT COUNT(*) AS n FROM (
         SELECT DATE(s.created_at) AS day FROM slowdowns s
          WHERE s.created_at < CURRENT_DATE() AND s.point_id IS NULL
            AND MBRContains(${GEOM}, s.location) AND ST_Distance_Sphere(s.location, ${GEOM}) <= ?
          GROUP BY day HAVING COUNT(DISTINCT s.user_id) >= 2) usual`,
      [boxWkt(input.lat, input.lng, r.radiusM * 2), center, r.radiusM],
    );
    if ((days?.n ?? 0) >= r.usualDays) return { counted: true, radar: null };

    // A police radar, where the drivers slowed down (the middle of the spots).
    const lat = near.reduce((sum, s) => sum + Number(s.lat), 0) / near.length;
    const lng = near.reduce((sum, s) => sum + Number(s.lng), 0) / near.length;
    const created = await execute(
      conn,
      `INSERT INTO points (type, lat, lng, visibility, status, source, created_by, expires_at)
       VALUES ('mobile', ?, ?, 'public', 'active', 'auto', NULL, CURRENT_TIMESTAMP(3) + INTERVAL ? MINUTE)`,
      [Math.round(lat * 1e6) / 1e6, Math.round(lng * 1e6) / 1e6, RULES.mobileLifetimeMin],
    );
    await execute(conn, 'UPDATE slowdowns SET point_id = ? WHERE id IN (?)', [created.insertId, near.map((s) => s.id)]);
    await refreshAutoRadar(conn, created.insertId);
    return { counted: true, radar: toApiPoint((await getRow(conn, created.insertId, user.id))!, user.id) };
  });
}

/**
 * Counts the different drivers who slowed down for this radar and keeps it
 * on the map [RULES.mobileLifetimeMin] after the latest one.
 */
async function refreshAutoRadar(conn: Queryable, pointId: number): Promise<void> {
  await execute(
    conn,
    `UPDATE points p SET
        p.slowdown_count = (SELECT COUNT(DISTINCT s.user_id) FROM slowdowns s WHERE s.point_id = p.id),
        p.expires_at = GREATEST(COALESCE(p.expires_at, CURRENT_TIMESTAMP(3)),
                                CURRENT_TIMESTAMP(3) + INTERVAL ? MINUTE)
      WHERE p.id = ?`,
    [RULES.mobileLifetimeMin, pointId],
  );
}
