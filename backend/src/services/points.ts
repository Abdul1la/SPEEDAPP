import type { AuthUser } from '../auth/auth.ts';
import { execute, select, selectOne, transaction } from '../db.ts';
import type { Db, Queryable } from '../db.ts';
import { badRequest, conflict, forbidden, notFound, tooMany } from '../lib/errors.ts';
import { GEOM, angleDifference, boxWkt, distanceMeters, pointWkt } from '../lib/geo.ts';

export type PointType = 'camera' | 'bump';
export type Visibility = 'public' | 'private';
export type PointStatus = 'active' | 'hidden' | 'removed';
export type StatusReason = 'votes' | 'reports' | 'moderator' | 'owner';
export type Vote = 'confirm' | 'gone';
export type ReportReason = 'fake' | 'wrong_place' | 'wrong_details' | 'duplicate' | 'other';

/** The community rules, in one place. */
export const RULES = {
  /** A new point of the same type this close to an existing one is the same point. */
  mergeRadiusM: 25,
  /** ...if their directions are this close (or one applies both ways). */
  mergeAngle: 45,
  /** "Gone" votes needed to hide a point (and more than its confirmations + 1). */
  goneVotesToHide: 3,
  /** Open reports from different drivers that hide a point until reviewed
   * (and more reports than confirmations, so a few accounts can't wipe
   * well-confirmed points). */
  reportsToHide: 3,
  /** A point other drivers confirmed can't be moved further than this by its owner. */
  maxOwnerMoveM: 200,
  maxRadiusM: 100_000,
  maxResults: 10_000,
  /** Changes are re-sent this long before the client's cursor, so none are missed. */
  syncOverlapS: 60,
};

export interface PointRow {
  id: number;
  type: PointType;
  lat: number;
  lng: number;
  speed_limit: number | null;
  direction: number | null;
  note: string | null;
  visibility: Visibility;
  status: PointStatus;
  status_reason: StatusReason | null;
  confirm_count: number;
  gone_count: number;
  report_count: number;
  last_confirmed_at: Date | null;
  created_by: number | null;
  client_id: string | null;
  source: 'app' | 'import' | 'admin';
  created_at: Date;
  updated_at: Date;
  my_vote?: Vote | null;
}

export interface ApiPoint {
  id: string;
  type: PointType;
  lat: number;
  lng: number;
  speedLimit: number | null;
  direction: number | null;
  note: string | null;
  visibility: Visibility;
  status: PointStatus;
  confirmCount: number;
  goneCount: number;
  lastConfirmedAt: string | null;
  /** True if the viewer added it (they can edit and delete it). */
  mine: boolean;
  myVote: Vote | null;
  /** The phone's own id for the point, only for the owner. */
  clientId?: string | null;
  createdAt: string;
  updatedAt: string;
}

export const POINT_COLUMNS =
  'p.id, p.type, p.lat, p.lng, p.speed_limit, p.direction, p.note, p.visibility, ' +
  'p.status, p.status_reason, p.confirm_count, p.gone_count, p.report_count, ' +
  'p.last_confirmed_at, p.created_by, p.client_id, p.source, p.created_at, p.updated_at';

/** SELECT of points with the viewer's vote (first parameter: viewer id). */
function selectPoints(where: string): string {
  return `SELECT ${POINT_COLUMNS}, v.vote AS my_vote
            FROM points p
            LEFT JOIN point_votes v ON v.point_id = p.id AND v.user_id = ?
           WHERE ${where}`;
}

export function toApiPoint(row: PointRow, viewerId: number | null): ApiPoint {
  const mine = viewerId != null && row.created_by === viewerId;
  return {
    id: String(row.id),
    type: row.type,
    lat: row.lat,
    lng: row.lng,
    speedLimit: row.speed_limit,
    direction: row.direction,
    note: row.note,
    visibility: row.visibility,
    status: row.status,
    confirmCount: row.confirm_count,
    goneCount: row.gone_count,
    lastConfirmedAt: row.last_confirmed_at?.toISOString() ?? null,
    mine,
    myVote: row.my_vote ?? null,
    ...(mine ? { clientId: row.client_id } : {}),
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

/** Can [viewerId] see this point on their map? */
export function isVisible(row: PointRow, viewerId: number): boolean {
  return (
    row.status === 'active' &&
    (row.visibility === 'public' || row.created_by === viewerId)
  );
}

export async function getRow(
  db: Queryable,
  id: number,
  viewerId: number,
  lock = false,
): Promise<PointRow | undefined> {
  return selectOne<PointRow>(
    db,
    selectPoints('p.id = ?') + (lock ? ' FOR UPDATE' : ''),
    [viewerId, id],
  );
}

// ---- Input ---------------------------------------------------------------

export interface PointInput {
  type?: PointType;
  lat?: number;
  lng?: number;
  speedLimit?: number | null;
  direction?: number | null;
  note?: string | null;
  visibility?: Visibility;
  clientId?: string | null;
}

/** Column values for the fields present in [input]. */
export function pointColumns(input: PointInput): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (input.type !== undefined) out.type = input.type;
  if (input.lat !== undefined) out.lat = input.lat;
  if (input.lng !== undefined) out.lng = input.lng;
  if (input.speedLimit !== undefined) {
    out.speed_limit = input.speedLimit == null ? null : Math.round(input.speedLimit);
  }
  if (input.direction !== undefined) {
    out.direction =
      input.direction == null ? null : ((Math.round(input.direction) % 360) + 360) % 360;
  }
  if (input.note !== undefined) out.note = input.note?.trim() || null;
  if (input.visibility !== undefined) out.visibility = input.visibility;
  return out;
}

function setClause(cols: Record<string, unknown>): [string, unknown[]] {
  const keys = Object.keys(cols);
  return [keys.map((k) => `${k} = ?`).join(', '), keys.map((k) => cols[k])];
}

export async function updateColumns(
  conn: Queryable,
  id: number,
  cols: Record<string, unknown>,
): Promise<void> {
  if (Object.keys(cols).length === 0) return;
  const [set, values] = setClause(cols);
  await execute(conn, `UPDATE points SET ${set} WHERE id = ?`, [...values, id]);
}

// ---- Counters and automatic hiding --------------------------------------

/**
 * Recalculates the vote / report counters of these points and applies the
 * community rules: enough "gone" votes or reports hide a point; enough
 * confirmations bring back a point hidden by votes.
 */
export async function recountPoints(conn: Queryable, ids: number[]): Promise<void> {
  const list = [...new Set(ids)];
  if (list.length === 0) return;
  await execute(
    conn,
    `UPDATE points p SET
        confirm_count = (SELECT COUNT(*) FROM point_votes v WHERE v.point_id = p.id AND v.vote = 'confirm'),
        gone_count = (SELECT COUNT(*) FROM point_votes v WHERE v.point_id = p.id AND v.vote = 'gone'),
        last_confirmed_at = (SELECT MAX(v.updated_at) FROM point_votes v WHERE v.point_id = p.id AND v.vote = 'confirm'),
        report_count = (SELECT COUNT(*) FROM point_reports r WHERE r.point_id = p.id AND r.status = 'open')
      WHERE p.id IN (?)`,
    [list],
  );
  // The driver who added a point counts as one confirmation (the "+ 1").
  await execute(
    conn,
    `UPDATE points SET status = 'hidden', status_reason = 'votes'
      WHERE id IN (?) AND status = 'active' AND gone_count >= ? AND gone_count > confirm_count + 1`,
    [list, RULES.goneVotesToHide],
  );
  await execute(
    conn,
    `UPDATE points SET status = 'active', status_reason = NULL
      WHERE id IN (?) AND status = 'hidden' AND status_reason = 'votes' AND gone_count <= confirm_count + 1`,
    [list],
  );
  await execute(
    conn,
    `UPDATE points SET status = 'hidden', status_reason = 'reports'
      WHERE id IN (?) AND status = 'active' AND report_count >= ? AND report_count > confirm_count`,
    [list, RULES.reportsToHide],
  );
  // Reports dismissed by a moderator: the point comes back.
  await execute(
    conn,
    `UPDATE points SET status = 'active', status_reason = NULL
      WHERE id IN (?) AND status = 'hidden' AND status_reason = 'reports'
        AND (report_count < ? OR report_count <= confirm_count)`,
    [list, RULES.reportsToHide],
  );
}

async function upsertVote(conn: Queryable, pointId: number, userId: number, vote: Vote) {
  await execute(
    conn,
    `INSERT INTO point_votes (point_id, user_id, vote) VALUES (?, ?, ?) AS new
     ON DUPLICATE KEY UPDATE vote = new.vote, updated_at = CURRENT_TIMESTAMP(3)`,
    [pointId, userId, vote],
  );
}

// ---- Create / edit / delete ----------------------------------------------

export interface CreateResult {
  point: ApiPoint;
  /** A new row was added. */
  created: boolean;
  /** Matched a point already on the map (counted as a confirmation). */
  merged: boolean;
}

export async function createPoint(
  db: Db,
  user: AuthUser,
  input: PointInput & { type: PointType; lat: number; lng: number },
  maxPerDay: number,
): Promise<CreateResult> {
  try {
    return await insertPoint(db, user, input, maxPerDay);
  } catch (e) {
    // The same upload sent twice at once: the second one returns the first.
    if ((e as { code?: string }).code === 'ER_DUP_ENTRY' && input.clientId) {
      const existing = await selectOne<PointRow>(
        db,
        selectPoints('p.created_by = ? AND p.client_id = ?'),
        [user.id, user.id, input.clientId],
      );
      if (existing) return { point: toApiPoint(existing, user.id), created: false, merged: false };
    }
    throw e;
  }
}

async function insertPoint(
  db: Db,
  user: AuthUser,
  input: PointInput & { type: PointType; lat: number; lng: number },
  maxPerDay: number,
): Promise<CreateResult> {
  const cols = pointColumns(input);
  const visibility = input.visibility ?? 'public';
  const direction = (cols.direction as number | null | undefined) ?? null;
  return transaction(db, async (conn) => {
    // Upload retried by the phone: return what was saved the first time.
    if (input.clientId) {
      const existing = await selectOne<PointRow>(
        conn,
        selectPoints('p.created_by = ? AND p.client_id = ?'),
        [user.id, user.id, input.clientId],
      );
      if (existing) {
        return { point: toApiPoint(existing, user.id), created: false, merged: false };
      }
    }

    const recent = await selectOne<{ n: number }>(
      conn,
      'SELECT COUNT(*) AS n FROM points WHERE created_by = ? AND created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 DAY',
      [user.id],
    );
    if ((recent?.n ?? 0) >= maxPerDay) {
      throw tooMany(`You can add up to ${maxPerDay} points a day. Try again tomorrow.`);
    }

    // Already on the map? Then this counts as "still there" instead.
    if (visibility === 'public') {
      const center = pointWkt(input.lat, input.lng);
      const near = await select<{ id: number; direction: number | null; created_by: number | null }>(
        conn,
        `SELECT p.id, p.direction, p.created_by FROM points p
          WHERE p.type = ? AND p.visibility = 'public'
            AND (p.status = 'active' OR (p.status = 'hidden' AND p.status_reason = 'votes'))
            AND MBRContains(${GEOM}, p.location)
            AND ST_Distance_Sphere(p.location, ${GEOM}) <= ?
          ORDER BY ST_Distance_Sphere(p.location, ${GEOM})
          LIMIT 5 FOR UPDATE`,
        [input.type, boxWkt(input.lat, input.lng, RULES.mergeRadiusM * 2), center, RULES.mergeRadiusM, center],
      );
      const same = near.find(
        (n) =>
          n.direction == null ||
          direction == null ||
          angleDifference(n.direction, direction) <= RULES.mergeAngle,
      );
      if (same) {
        if (same.created_by !== user.id) {
          await upsertVote(conn, same.id, user.id, 'confirm');
          await recountPoints(conn, [same.id]);
        }
        const row = (await getRow(conn, same.id, user.id))!;
        return { point: toApiPoint(row, user.id), created: false, merged: true };
      }
    }

    const insert = {
      ...cols,
      visibility,
      created_by: user.id,
      client_id: input.clientId ?? null,
      source: 'app',
    };
    const keys = Object.keys(insert);
    const r = await execute(
      conn,
      `INSERT INTO points (${keys.join(', ')}) VALUES (${keys.map(() => '?').join(', ')})`,
      keys.map((k) => insert[k as keyof typeof insert]),
    );
    const row = (await getRow(conn, r.insertId, user.id))!;
    return { point: toApiPoint(row, user.id), created: true, merged: false };
  });
}

/** The owner changes their point. */
export async function updatePoint(
  db: Db,
  user: AuthUser,
  id: number,
  input: PointInput,
): Promise<ApiPoint> {
  return transaction(db, async (conn) => {
    const row = await getRow(conn, id, user.id, true);
    if (!row || row.status === 'removed') throw notFound('This point no longer exists.');
    if (row.created_by !== user.id) {
      if (!isVisible(row, user.id)) throw notFound('This point no longer exists.');
      throw forbidden('not_owner', 'Only the driver who added this point can change it.');
    }
    const cols = pointColumns(input);
    // Other drivers rely on a point they confirmed: it can't be taken away
    // by making it private or moving it far.
    const others = await othersConfirmed(conn, id, user.id);
    if (others > 0 && row.visibility === 'public') {
      if (input.visibility === 'private') {
        throw badRequest('confirmed_by_others', 'Other drivers confirmed this point, so it stays shared.');
      }
      if (input.lat !== undefined || input.lng !== undefined) {
        const moved = distanceMeters(row.lat, row.lng, input.lat ?? row.lat, input.lng ?? row.lng);
        if (moved > RULES.maxOwnerMoveM) {
          throw badRequest(
            'confirmed_by_others',
            `Other drivers confirmed this point, so it can only be moved up to ${RULES.maxOwnerMoveM} m.`,
          );
        }
      }
    }
    if (input.visibility === 'private' && row.visibility === 'public') cols.unshared_at = new Date();
    await updateColumns(conn, id, cols);
    return toApiPoint((await getRow(conn, id, user.id))!, user.id);
  });
}

/**
 * The owner deletes their point. If other drivers confirmed it, it stays on
 * the map for them (owned by the community) and the owner's delete counts
 * as a "gone" vote.
 */
export async function deletePoint(
  db: Db,
  user: AuthUser,
  id: number,
): Promise<{ removed: boolean; kept: boolean }> {
  return transaction(db, async (conn) => {
    const row = await getRow(conn, id, user.id, true);
    if (!row) throw notFound('This point no longer exists.');
    if (row.status === 'removed') return { removed: true, kept: false };
    if (row.created_by !== user.id) {
      // Deleted before and kept by the community: repeat the same answer.
      if (row.created_by == null && row.my_vote === 'gone') return { removed: false, kept: true };
      if (!isVisible(row, user.id)) throw notFound('This point no longer exists.');
      throw forbidden('not_owner', 'Only the driver who added this point can delete it.');
    }
    const others = await othersConfirmed(conn, id, user.id);
    if (row.visibility === 'private' || others === 0) {
      await updateColumns(conn, id, { status: 'removed', status_reason: 'owner' });
      return { removed: true, kept: false };
    }
    await updateColumns(conn, id, { created_by: null, client_id: null });
    await upsertVote(conn, id, user.id, 'gone');
    await recountPoints(conn, [id]);
    return { removed: false, kept: true };
  });
}

async function othersConfirmed(conn: Queryable, id: number, ownerId: number): Promise<number> {
  const r = await selectOne<{ n: number }>(
    conn,
    "SELECT COUNT(*) AS n FROM point_votes WHERE point_id = ? AND vote = 'confirm' AND user_id <> ?",
    [id, ownerId],
  );
  return r?.n ?? 0;
}

// ---- Votes and reports ---------------------------------------------------

/** A point drivers can vote on: shown on the map, or hidden only by votes
 * (so confirmations can bring it back). */
async function mustSeeForCommunity(conn: Queryable, id: number, user: AuthUser): Promise<PointRow> {
  const row = await getRow(conn, id, user.id, true);
  const votable =
    row != null &&
    (row.visibility === 'public' || row.created_by === user.id) &&
    (row.status === 'active' || (row.status === 'hidden' && row.status_reason === 'votes'));
  if (!row || !votable) {
    throw notFound('This point no longer exists.');
  }
  if (row.created_by === user.id) {
    throw badRequest('own_point', 'You added this point. Edit or delete it instead.');
  }
  return row;
}

export async function votePoint(db: Db, user: AuthUser, id: number, vote: Vote): Promise<ApiPoint> {
  return transaction(db, async (conn) => {
    await mustSeeForCommunity(conn, id, user);
    await upsertVote(conn, id, user.id, vote);
    await recountPoints(conn, [id]);
    return toApiPoint((await getRow(conn, id, user.id))!, user.id);
  });
}

export async function unvotePoint(db: Db, user: AuthUser, id: number): Promise<ApiPoint> {
  return transaction(db, async (conn) => {
    await mustSeeForCommunity(conn, id, user);
    await execute(conn, 'DELETE FROM point_votes WHERE point_id = ? AND user_id = ?', [id, user.id]);
    await recountPoints(conn, [id]);
    return toApiPoint((await getRow(conn, id, user.id))!, user.id);
  });
}

export async function reportPoint(
  db: Db,
  user: AuthUser,
  id: number,
  reason: ReportReason,
  comment: string | null,
): Promise<{ id: string }> {
  return transaction(db, async (conn) => {
    await mustSeeForCommunity(conn, id, user);
    const open = await selectOne<{ id: number }>(
      conn,
      "SELECT id FROM point_reports WHERE point_id = ? AND user_id = ? AND status = 'open'",
      [id, user.id],
    );
    if (open) throw conflict('already_reported', 'You already reported this point.');
    const r = await execute(
      conn,
      'INSERT INTO point_reports (point_id, user_id, reason, comment) VALUES (?, ?, ?, ?)',
      [id, user.id, reason, comment?.trim() || null],
    );
    await recountPoints(conn, [id]);
    return { id: String(r.insertId) };
  });
}

// ---- Reading -------------------------------------------------------------

export async function getPoint(db: Db, user: AuthUser, id: number): Promise<ApiPoint> {
  const row = await getRow(db, id, user.id);
  if (!row || !isVisible(row, user.id)) throw notFound('This point no longer exists.');
  return toApiPoint(row, user.id);
}

export interface NearbyResult {
  points: ApiPoint[];
  /** Ids to delete from the phone's copy (removed, hidden or made private). */
  removed: string[];
  /** Pass back as `since` next time to get only what changed. */
  serverTime: string;
  /** More points than [RULES.maxResults]: ask for a smaller radius. */
  truncated: boolean;
}

/**
 * Points within [radiusM] of a place. Without [since]: everything visible.
 * With [since]: only what changed after it, including what to remove.
 */
export async function nearby(
  db: Db,
  user: AuthUser,
  q: { lat: number; lng: number; radiusM: number; since?: Date | null },
): Promise<NearbyResult> {
  const now = (await selectOne<{ now: Date }>(db, 'SELECT CURRENT_TIMESTAMP(3) AS now'))!.now;
  const radius = Math.min(q.radiusM, RULES.maxRadiusM);
  const center = pointWkt(q.lat, q.lng);
  const where = [`MBRContains(${GEOM}, p.location)`, `ST_Distance_Sphere(p.location, ${GEOM}) <= ?`];
  const params: unknown[] = [user.id, boxWkt(q.lat, q.lng, radius), center, radius];
  if (q.since) {
    const since = new Date(q.since.getTime() - RULES.syncOverlapS * 1000);
    // Other drivers' private points are never sent, not even their ids,
    // except ones made private since (phones that saw them must remove them).
    where.push('p.updated_at > ?', "(p.visibility = 'public' OR p.created_by = ? OR p.unshared_at > ?)");
    params.push(since, user.id, since);
  } else {
    where.push("p.status = 'active'", "(p.visibility = 'public' OR p.created_by = ?)");
    params.push(user.id);
  }
  const order = q.since ? ' ORDER BY p.updated_at, p.id' : '';
  const rows = await select<PointRow>(db, `${selectPoints(where.join(' AND '))}${order} LIMIT ?`, [
    ...params,
    RULES.maxResults,
  ]);
  const truncated = rows.length >= RULES.maxResults;
  const points: ApiPoint[] = [];
  const removed: string[] = [];
  for (const row of rows) {
    if (isVisible(row, user.id)) points.push(toApiPoint(row, user.id));
    else removed.push(String(row.id));
  }
  // When a delta was cut short, continue from the last change sent.
  const last = rows[rows.length - 1];
  const cursor = truncated && q.since && last ? last.updated_at : now;
  return { points, removed, serverTime: cursor.toISOString(), truncated };
}

/** Everything the user added (for restoring on a new phone). */
export async function myPoints(db: Db, user: AuthUser): Promise<ApiPoint[]> {
  const rows = await select<PointRow>(
    db,
    `${selectPoints("p.created_by = ? AND p.status <> 'removed'")} ORDER BY p.id`,
    [user.id, user.id],
  );
  return rows.map((r) => toApiPoint(r, user.id));
}
