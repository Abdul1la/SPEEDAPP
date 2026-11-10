import { hasRole } from '../auth/auth.ts';
import type { AuthUser, Role } from '../auth/auth.ts';
import { execute, select, selectOne, transaction } from '../db.ts';
import type { Db, Queryable } from '../db.ts';
import { badRequest, forbidden, notFound } from '../lib/errors.ts';
import {
  POINT_COLUMNS,
  getRow,
  pointColumns,
  recountPoints,
  toApiPoint,
  updateColumns,
} from './points.ts';
import type { ApiPoint, PointInput, PointRow, PointStatus } from './points.ts';
import { USER_COLUMNS, getUser, toApiUser } from './users.ts';
import type { ApiUser, UserRow } from './users.ts';

type Target = 'point' | 'user' | 'report';

export async function audit(
  conn: Queryable,
  actor: AuthUser,
  action: string,
  targetType: Target,
  targetId: number,
  details: Record<string, unknown> | null = null,
): Promise<void> {
  await execute(
    conn,
    'INSERT INTO audit_log (actor_id, action, target_type, target_id, details) VALUES (?, ?, ?, ?, CAST(? AS JSON))',
    [actor.id, action, targetType, targetId, details == null ? null : JSON.stringify(details)],
  );
}

export interface Page {
  limit: number;
  offset: number;
}

/** A point as moderators see it: who added it, why it is hidden... */
export interface AdminPoint extends ApiPoint {
  statusReason: string | null;
  reportCount: number;
  source: string;
  owner: { id: string; email: string | null; displayName: string | null; status: string } | null;
}

interface AdminPointRow extends PointRow {
  owner_email: string | null;
  owner_name: string | null;
  owner_status: string | null;
}

const ADMIN_POINT_SELECT = `
  SELECT ${POINT_COLUMNS}, NULL AS my_vote,
         u.email AS owner_email, u.display_name AS owner_name, u.status AS owner_status
    FROM points p LEFT JOIN users u ON u.id = p.created_by`;

function toAdminPoint(row: AdminPointRow): AdminPoint {
  return {
    ...toApiPoint(row, null),
    clientId: row.client_id,
    statusReason: row.status_reason,
    reportCount: row.report_count,
    source: row.source,
    owner:
      row.created_by == null
        ? null
        : {
            id: String(row.created_by),
            email: row.owner_email,
            displayName: row.owner_name,
            status: row.owner_status ?? 'active',
          },
  };
}

async function adminPoint(conn: Queryable, id: number): Promise<AdminPoint> {
  const row = await selectOne<AdminPointRow>(conn, `${ADMIN_POINT_SELECT} WHERE p.id = ?`, [id]);
  if (!row) throw notFound('Point not found.');
  return toAdminPoint(row);
}

// ---- Overview ------------------------------------------------------------

export async function stats(db: Db) {
  const [users, points, reports, day] = await Promise.all([
    selectOne<Record<string, number>>(
      db,
      `SELECT COUNT(*) AS total, COALESCE(SUM(email IS NOT NULL), 0) AS registered,
              COALESCE(SUM(status = 'banned'), 0) AS banned,
              COALESCE(SUM(last_seen_at > CURRENT_TIMESTAMP(3) - INTERVAL 7 DAY), 0) AS active7d
         FROM users`,
    ),
    selectOne<Record<string, number>>(
      db,
      `SELECT COALESCE(SUM(status = 'active'), 0) AS active, COALESCE(SUM(status = 'hidden'), 0) AS hidden,
              COALESCE(SUM(status = 'removed'), 0) AS removed,
              COALESCE(SUM(status = 'active' AND type = 'camera'), 0) AS cameras,
              COALESCE(SUM(status = 'active' AND type = 'bump'), 0) AS bumps,
              COALESCE(SUM(status = 'active' AND visibility = 'private'), 0) AS private
         FROM points`,
    ),
    selectOne<Record<string, number>>(db, "SELECT COUNT(*) AS open FROM point_reports WHERE status = 'open'"),
    selectOne<Record<string, number>>(
      db,
      `SELECT (SELECT COUNT(*) FROM points WHERE created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 DAY) AS points,
              (SELECT COUNT(*) FROM point_votes WHERE updated_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 DAY) AS votes,
              (SELECT COUNT(*) FROM point_reports WHERE created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 DAY) AS reports,
              (SELECT COUNT(*) FROM users WHERE created_at > CURRENT_TIMESTAMP(3) - INTERVAL 1 DAY) AS users`,
    ),
  ]);
  return { users, points, reports, last24h: day };
}

// ---- Reports -------------------------------------------------------------

export type ReportAction = 'dismiss' | 'keep_point' | 'hide_point' | 'remove_point';

export async function listReports(db: Db, status: string, page: Page) {
  const rows = await select<{
    id: number;
    point_id: number;
    reason: string;
    comment: string | null;
    status: string;
    created_at: Date;
    resolved_at: Date | null;
    resolution_note: string | null;
    user_id: number | null;
    reporter_email: string | null;
    reporter_name: string | null;
  }>(
    db,
    `SELECT r.id, r.point_id, r.reason, r.comment, r.status, r.created_at, r.resolved_at,
            r.resolution_note, r.user_id, u.email AS reporter_email, u.display_name AS reporter_name
       FROM point_reports r LEFT JOIN users u ON u.id = r.user_id
      WHERE r.status = ?
      ORDER BY r.created_at ${status === 'open' ? 'ASC' : 'DESC'}
      LIMIT ? OFFSET ?`,
    [status, page.limit, page.offset],
  );
  const ids = [...new Set(rows.map((r) => r.point_id))];
  const points = ids.length
    ? await select<AdminPointRow>(db, `${ADMIN_POINT_SELECT} WHERE p.id IN (?)`, [ids])
    : [];
  const byId = new Map(points.map((p) => [p.id, toAdminPoint(p)]));
  return rows.map((r) => ({
    id: String(r.id),
    reason: r.reason,
    comment: r.comment,
    status: r.status,
    createdAt: r.created_at.toISOString(),
    resolvedAt: r.resolved_at?.toISOString() ?? null,
    resolutionNote: r.resolution_note,
    reporter:
      r.user_id == null
        ? null
        : { id: String(r.user_id), email: r.reporter_email, displayName: r.reporter_name },
    point: byId.get(r.point_id) ?? null,
  }));
}

/**
 * Closes a report:
 *  - dismiss: only this report is wrong.
 *  - keep_point: the point is fine; closes all its open reports and brings
 *    it back if reports hid it.
 *  - hide_point / remove_point: takes the point off the map; closes all its
 *    open reports.
 */
export async function resolveReport(
  db: Db,
  actor: AuthUser,
  reportId: number,
  action: ReportAction,
  note: string | null,
): Promise<{ point: AdminPoint }> {
  return transaction(db, async (conn) => {
    const report = await selectOne<{ id: number; point_id: number; status: string }>(
      conn,
      'SELECT id, point_id, status FROM point_reports WHERE id = ? FOR UPDATE',
      [reportId],
    );
    if (!report) throw notFound('Report not found.');
    if (report.status !== 'open') throw badRequest('already_closed', 'This report is already closed.');
    const pointId = report.point_id;
    const close = (status: 'resolved' | 'dismissed', onlyThis: boolean) =>
      execute(
        conn,
        `UPDATE point_reports SET status = ?, resolved_by = ?, resolved_at = CURRENT_TIMESTAMP(3), resolution_note = ?
          WHERE status = 'open' AND ${onlyThis ? 'id = ?' : 'point_id = ?'}`,
        [status, actor.id, note, onlyThis ? reportId : pointId],
      );

    switch (action) {
      case 'dismiss':
        await close('dismissed', true);
        break;
      case 'keep_point':
        await close('dismissed', false);
        await execute(
          conn,
          "UPDATE points SET status = 'active', status_reason = NULL WHERE id = ? AND status = 'hidden' AND status_reason = 'reports'",
          [pointId],
        );
        break;
      case 'hide_point':
      case 'remove_point':
        await close('resolved', false);
        await updateColumns(conn, pointId, {
          status: action === 'hide_point' ? 'hidden' : 'removed',
          status_reason: 'moderator',
        });
        break;
    }
    await recountPoints(conn, [pointId]);
    await audit(conn, actor, `report.${action}`, 'report', reportId, { pointId, note });
    return { point: await adminPoint(conn, pointId) };
  });
}

// ---- Points --------------------------------------------------------------

export async function listPoints(
  db: Db,
  filter: { status?: PointStatus; reported?: boolean; q?: string; ownerId?: number },
  page: Page,
): Promise<AdminPoint[]> {
  const where: string[] = [];
  const params: unknown[] = [];
  if (filter.status) {
    where.push('p.status = ?');
    params.push(filter.status);
  }
  if (filter.reported) where.push('p.report_count > 0');
  if (filter.ownerId) {
    where.push('p.created_by = ?');
    params.push(filter.ownerId);
  }
  if (filter.q) {
    if (/^\d+$/.test(filter.q)) {
      where.push('p.id = ?');
      params.push(Number(filter.q));
    } else {
      where.push('(p.note LIKE ? OR u.email LIKE ?)');
      params.push(`%${filter.q}%`, `%${filter.q}%`);
    }
  }
  const rows = await select<AdminPointRow>(
    db,
    `${ADMIN_POINT_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY p.updated_at DESC LIMIT ? OFFSET ?`,
    [...params, page.limit, page.offset],
  );
  return rows.map(toAdminPoint);
}

export async function getAdminPoint(db: Db, id: number) {
  const point = await adminPoint(db, id);
  const votes = await select<{ vote: string; n: number }>(
    db,
    'SELECT vote, COUNT(*) AS n FROM point_votes WHERE point_id = ? GROUP BY vote',
    [id],
  );
  const history = await select<{ action: string; created_at: Date; actor_email: string | null; details: unknown }>(
    db,
    `SELECT a.action, a.created_at, u.email AS actor_email, a.details
       FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id
      WHERE a.target_type = 'point' AND a.target_id = ?
      ORDER BY a.id DESC LIMIT 50`,
    [id],
  );
  return {
    point,
    votes: Object.fromEntries(votes.map((v) => [v.vote, v.n])),
    history: history.map((h) => ({
      action: h.action,
      at: h.created_at.toISOString(),
      by: h.actor_email,
      details: h.details,
    })),
  };
}

export async function editPoint(
  db: Db,
  actor: AuthUser,
  id: number,
  input: PointInput & { status?: PointStatus },
): Promise<AdminPoint> {
  return transaction(db, async (conn) => {
    const row = await getRow(conn, id, actor.id, true);
    if (!row) throw notFound('Point not found.');
    const cols = pointColumns(input);
    if (input.status !== undefined) {
      cols.status = input.status;
      cols.status_reason = input.status === 'active' ? null : 'moderator';
    }
    if (input.visibility === 'private' && row.visibility === 'public') cols.unshared_at = new Date();
    await updateColumns(conn, id, cols);
    if (input.status === 'active') {
      // Restored by a moderator: its open reports are answered, so the next
      // vote doesn't hide it again.
      await execute(
        conn,
        `UPDATE point_reports SET status = 'dismissed', resolved_by = ?, resolved_at = CURRENT_TIMESTAMP(3),
                resolution_note = 'Point restored by a moderator'
          WHERE point_id = ? AND status = 'open'`,
        [actor.id, id],
      );
      await recountPoints(conn, [id]);
    }
    await audit(conn, actor, 'point.edit', 'point', id, { changes: input });
    return adminPoint(conn, id);
  });
}

// ---- Users ---------------------------------------------------------------

export interface AdminUser extends ApiUser {
  status: string;
  banReason: string | null;
  lastSeenAt: string | null;
  points: number;
  openReportsAgainst: number;
}

interface AdminUserRow extends UserRow {
  point_count: number;
  reports_against: number;
}

const ADMIN_USER_SELECT = `
  SELECT ${USER_COLUMNS},
         (SELECT COUNT(*) FROM points p WHERE p.created_by = u.id AND p.status <> 'removed') AS point_count,
         (SELECT COUNT(*) FROM point_reports r JOIN points p ON p.id = r.point_id
           WHERE p.created_by = u.id AND r.status = 'open') AS reports_against
    FROM users u`;

function toAdminUser(row: AdminUserRow): AdminUser {
  return {
    ...toApiUser(row),
    status: row.status,
    banReason: row.ban_reason,
    lastSeenAt: row.last_seen_at?.toISOString() ?? null,
    points: row.point_count,
    openReportsAgainst: row.reports_against,
  };
}

async function adminUser(conn: Queryable, id: number): Promise<AdminUser> {
  const row = await selectOne<AdminUserRow>(conn, `${ADMIN_USER_SELECT} WHERE u.id = ?`, [id]);
  if (!row) throw notFound('User not found.');
  return toAdminUser(row);
}

export async function listUsers(
  db: Db,
  filter: { q?: string; status?: string; role?: string },
  page: Page,
): Promise<AdminUser[]> {
  const where: string[] = [];
  const params: unknown[] = [];
  if (filter.status) {
    where.push('u.status = ?');
    params.push(filter.status);
  }
  if (filter.role) {
    where.push('u.role = ?');
    params.push(filter.role);
  }
  if (filter.q) {
    if (/^\d+$/.test(filter.q)) {
      where.push('u.id = ?');
      params.push(Number(filter.q));
    } else {
      where.push('(u.email LIKE ? OR u.display_name LIKE ?)');
      params.push(`%${filter.q}%`, `%${filter.q}%`);
    }
  }
  const rows = await select<AdminUserRow>(
    db,
    `${ADMIN_USER_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY u.id DESC LIMIT ? OFFSET ?`,
    [...params, page.limit, page.offset],
  );
  return rows.map(toAdminUser);
}

export async function getAdminUser(db: Db, id: number): Promise<AdminUser> {
  return adminUser(db, id);
}

/** Moderators can act on drivers; only admins can act on staff. */
async function mustManage(conn: Queryable, actor: AuthUser, targetId: number): Promise<UserRow> {
  const target = await getUser(conn, targetId);
  if (!target) throw notFound('User not found.');
  if (target.id === actor.id) throw badRequest('self', 'You cannot do this to your own account.');
  if (target.role !== 'user' && !hasRole(actor, 'admin')) {
    throw forbidden('forbidden', 'Only an admin can change moderators and admins.');
  }
  return target;
}

/** Blocks a user (they are signed out everywhere); optionally hides their public points. */
export async function banUser(
  db: Db,
  actor: AuthUser,
  id: number,
  reason: string | null,
  hidePoints: boolean,
): Promise<{ user: AdminUser; hiddenPoints: number }> {
  return transaction(db, async (conn) => {
    await mustManage(conn, actor, id);
    await execute(conn, "UPDATE users SET status = 'banned', ban_reason = ? WHERE id = ?", [reason, id]);
    await execute(
      conn,
      'UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP(3) WHERE user_id = ? AND revoked_at IS NULL',
      [id],
    );
    let hidden = 0;
    if (hidePoints) {
      const r = await execute(
        conn,
        "UPDATE points SET status = 'hidden', status_reason = 'moderator' WHERE created_by = ? AND status = 'active'",
        [id],
      );
      hidden = r.affectedRows;
    }
    // Undo their votes and open reports, so a banned troll's "gone" votes and
    // fake reports stop hiding other drivers' points.
    const touched = await select<{ point_id: number }>(
      conn,
      `SELECT point_id FROM point_votes WHERE user_id = ?
        UNION SELECT point_id FROM point_reports WHERE user_id = ? AND status = 'open'`,
      [id, id],
    );
    await execute(conn, 'DELETE FROM point_votes WHERE user_id = ?', [id]);
    await execute(
      conn,
      `UPDATE point_reports SET status = 'dismissed', resolved_by = ?, resolved_at = CURRENT_TIMESTAMP(3),
              resolution_note = 'Reporter was banned'
        WHERE user_id = ? AND status = 'open'`,
      [actor.id, id],
    );
    await recountPoints(conn, touched.map((t) => t.point_id));
    await audit(conn, actor, 'user.ban', 'user', id, {
      reason,
      hidePoints,
      hiddenPoints: hidden,
      undoneVotesAndReports: touched.length,
    });
    return { user: await adminUser(conn, id), hiddenPoints: hidden };
  });
}

export async function unbanUser(db: Db, actor: AuthUser, id: number): Promise<AdminUser> {
  return transaction(db, async (conn) => {
    await mustManage(conn, actor, id);
    await execute(conn, "UPDATE users SET status = 'active', ban_reason = NULL WHERE id = ?", [id]);
    await audit(conn, actor, 'user.unban', 'user', id);
    return adminUser(conn, id);
  });
}

export async function setRole(db: Db, actor: AuthUser, id: number, role: Role): Promise<AdminUser> {
  if (!hasRole(actor, 'admin')) throw forbidden('forbidden', 'Only an admin can change roles.');
  return transaction(db, async (conn) => {
    const target = await mustManage(conn, actor, id);
    if (role !== 'user' && target.email == null) {
      throw badRequest('anonymous', 'Staff need an account with email and password.');
    }
    await execute(conn, 'UPDATE users SET role = ? WHERE id = ?', [role, id]);
    await audit(conn, actor, 'user.role', 'user', id, { from: target.role, to: role });
    return adminUser(conn, id);
  });
}

// ---- Audit log -----------------------------------------------------------

export async function listAudit(db: Db, page: Page) {
  const rows = await select<{
    id: number;
    action: string;
    target_type: string;
    target_id: number;
    details: unknown;
    created_at: Date;
    actor_id: number | null;
    actor_email: string | null;
  }>(
    db,
    `SELECT a.id, a.action, a.target_type, a.target_id, a.details, a.created_at, a.actor_id, u.email AS actor_email
       FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id
      ORDER BY a.id DESC LIMIT ? OFFSET ?`,
    [page.limit, page.offset],
  );
  return rows.map((r) => ({
    id: String(r.id),
    action: r.action,
    target: { type: r.target_type, id: String(r.target_id) },
    details: r.details,
    at: r.created_at.toISOString(),
    actor: r.actor_id == null ? null : { id: String(r.actor_id), email: r.actor_email },
  }));
}
