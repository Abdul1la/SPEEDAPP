import { createSession } from '../auth/auth.ts';
import type { AuthUser, Role } from '../auth/auth.ts';
import {
  dummyPasswordHash,
  hashPassword,
  verifyPassword,
} from '../auth/crypto.ts';
import { execute, select, selectOne, transaction } from '../db.ts';
import type { Db, Queryable } from '../db.ts';
import { ApiError, badRequest, conflict, forbidden } from '../lib/errors.ts';
import { recountPoints } from './points.ts';

export interface UserRow {
  id: number;
  email: string | null;
  display_name: string | null;
  role: Role;
  status: 'active' | 'banned';
  ban_reason: string | null;
  created_at: Date;
  last_seen_at: Date | null;
}

export interface ApiUser {
  id: string;
  email: string | null;
  displayName: string | null;
  role: Role;
  isAnonymous: boolean;
  createdAt: string;
}

export const USER_COLUMNS =
  'u.id, u.email, u.display_name, u.role, u.status, u.ban_reason, u.created_at, u.last_seen_at';

export function toApiUser(row: UserRow): ApiUser {
  return {
    id: String(row.id),
    email: row.email,
    displayName: row.display_name,
    role: row.role,
    isAnonymous: row.email == null,
    createdAt: row.created_at.toISOString(),
  };
}

export async function getUser(db: Queryable, id: number): Promise<UserRow | undefined> {
  return selectOne<UserRow>(db, `SELECT ${USER_COLUMNS} FROM users u WHERE u.id = ?`, [id]);
}

async function mustGetUser(db: Queryable, id: number): Promise<UserRow> {
  const row = await getUser(db, id);
  if (!row) throw new ApiError(404, 'not_found', 'User not found.');
  return row;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const STAFF_SESSION_DAYS = 30;

function cleanEmail(email: string): string {
  const e = email.trim().toLowerCase();
  if (!EMAIL_RE.test(e) || e.length > 254) {
    throw badRequest('invalid_email', 'Enter a valid email address.');
  }
  return e;
}

function checkPassword(password: string) {
  if (password.length < 8) {
    throw badRequest('weak_password', 'Use at least 8 characters for the password.');
  }
  if (password.length > 200) {
    throw badRequest('weak_password', 'That password is too long.');
  }
}

export interface Signed {
  token: string;
  user: ApiUser;
}

/** A new driver without email (the app does this on first start). */
export async function createAnonymous(db: Db, deviceName: string | null): Promise<Signed> {
  return transaction(db, async (conn) => {
    const r = await execute(conn, 'INSERT INTO users () VALUES ()');
    const token = await createSession(conn, r.insertId, deviceName);
    return { token, user: toApiUser(await mustGetUser(conn, r.insertId)) };
  });
}

/**
 * Adds email + password. When [current] is an anonymous driver, their
 * account (and points) is kept and upgraded; otherwise a new account is made.
 */
export async function register(
  db: Db,
  current: AuthUser | null,
  input: { email: string; password: string; displayName?: string | null; deviceName?: string | null },
): Promise<Signed> {
  const email = cleanEmail(input.email);
  checkPassword(input.password);
  if (current && !current.isAnonymous) {
    throw badRequest('already_registered', 'You already have an account. Sign out first.');
  }
  const hash = await hashPassword(input.password);
  const displayName = input.displayName?.trim() || null;
  try {
    return await transaction(db, async (conn) => {
      let id: number;
      if (current) {
        id = current.id;
        await execute(
          conn,
          'UPDATE users SET email = ?, password_hash = ?, display_name = COALESCE(?, display_name) WHERE id = ?',
          [email, hash, displayName, id],
        );
      } else {
        const r = await execute(
          conn,
          'INSERT INTO users (email, password_hash, display_name) VALUES (?, ?, ?)',
          [email, hash, displayName],
        );
        id = r.insertId;
      }
      const token = await createSession(conn, id, input.deviceName ?? null);
      return { token, user: toApiUser(await mustGetUser(conn, id)) };
    });
  } catch (e) {
    if ((e as { code?: string }).code === 'ER_DUP_ENTRY') {
      throw conflict('email_taken', 'An account with this email already exists. Sign in instead.');
    }
    throw e;
  }
}

/**
 * Signs in with email + password. If the phone was using an anonymous
 * account ([current]), its points, votes and reports move into the account
 * and the anonymous account is deleted.
 */
export async function login(
  db: Db,
  current: AuthUser | null,
  input: { email: string; password: string; deviceName?: string | null },
  sessionDays: number | null = null,
): Promise<Signed & { merged: number }> {
  const email = input.email.trim().toLowerCase();
  const row = await selectOne<{
    id: number;
    password_hash: string | null;
    status: string;
    ban_reason: string | null;
    role: Role;
  }>(db, 'SELECT id, password_hash, status, ban_reason, role FROM users WHERE email = ?', [email]);
  const ok = await verifyPassword(input.password, row?.password_hash ?? dummyPasswordHash);
  if (!row || !ok) {
    throw new ApiError(401, 'invalid_login', 'Wrong email or password.');
  }
  if (row.status === 'banned') {
    throw forbidden('banned', row.ban_reason ? `This account is blocked: ${row.ban_reason}` : 'This account is blocked.');
  }
  return transaction(db, async (conn) => {
    let merged = 0;
    if (current?.isAnonymous && current.id !== row.id) {
      merged = await mergeInto(conn, current.id, row.id);
    }
    // Staff sign-ins (moderation rights) always expire, at most after 30 days.
    const days = row.role === 'user' ? sessionDays : Math.min(sessionDays ?? STAFF_SESSION_DAYS, STAFF_SESSION_DAYS);
    const token = await createSession(conn, row.id, input.deviceName ?? null, days);
    return { token, user: toApiUser(await mustGetUser(conn, row.id)), merged };
  });
}

/** Moves everything of user [from] to user [to], then deletes [from]. */
async function mergeInto(conn: Queryable, from: number, to: number): Promise<number> {
  // The same point uploaded to both accounts (same phone id): keep the
  // account's copy, so nothing is left without an owner.
  await execute(
    conn,
    `DELETE a FROM points a
       JOIN points t ON t.created_by = ? AND t.client_id = a.client_id
      WHERE a.created_by = ? AND a.client_id IS NOT NULL`,
    [to, from],
  );
  const moved = await execute(conn, 'UPDATE points SET created_by = ? WHERE created_by = ?', [to, from]);
  const touched = await select<{ point_id: number }>(
    conn,
    `SELECT point_id FROM point_votes WHERE user_id IN (?, ?)
      UNION SELECT point_id FROM point_reports WHERE user_id IN (?, ?)`,
    [from, to, from, to],
  );
  // Votes on points the account owns or already voted on are dropped.
  await execute(conn, 'UPDATE IGNORE point_votes SET user_id = ? WHERE user_id = ?', [to, from]);
  await execute(
    conn,
    `DELETE v FROM point_votes v JOIN points p ON p.id = v.point_id
      WHERE v.user_id = ? AND p.created_by = ?`,
    [to, to],
  );
  await execute(conn, 'UPDATE point_reports SET user_id = ? WHERE user_id = ?', [to, from]);
  // No reports on your own points, and one open report per point.
  await execute(
    conn,
    `UPDATE point_reports r JOIN points p ON p.id = r.point_id
        SET r.status = 'dismissed', r.resolution_note = 'Reporter owns the point'
      WHERE r.user_id = ? AND p.created_by = ? AND r.status = 'open'`,
    [to, to],
  );
  await execute(
    conn,
    `UPDATE point_reports r1 JOIN point_reports r2
         ON r2.point_id = r1.point_id AND r2.user_id = r1.user_id AND r2.status = 'open' AND r2.id < r1.id
        SET r1.status = 'dismissed', r1.resolution_note = 'Duplicate report'
      WHERE r1.user_id = ? AND r1.status = 'open'`,
    [to],
  );
  await execute(
    conn,
    `INSERT IGNORE INTO user_settings (user_id, settings)
     SELECT ?, settings FROM user_settings WHERE user_id = ?`,
    [to, from],
  );
  await execute(conn, 'DELETE FROM users WHERE id = ?', [from]);
  await recountPoints(conn, touched.map((v) => v.point_id));
  return moved.affectedRows;
}

export async function logout(db: Db, user: AuthUser): Promise<void> {
  await execute(db, 'UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP(3) WHERE id = ?', [user.sessionId]);
}

export async function changePassword(
  db: Db,
  user: AuthUser,
  input: { currentPassword: string; newPassword: string },
): Promise<void> {
  if (user.isAnonymous) throw badRequest('no_password', 'This account has no password yet.');
  checkPassword(input.newPassword);
  const row = await selectOne<{ password_hash: string }>(db, 'SELECT password_hash FROM users WHERE id = ?', [user.id]);
  if (!row || !(await verifyPassword(input.currentPassword, row.password_hash))) {
    throw new ApiError(401, 'invalid_login', 'The current password is wrong.');
  }
  const hash = await hashPassword(input.newPassword);
  await transaction(db, async (conn) => {
    await execute(conn, 'UPDATE users SET password_hash = ? WHERE id = ?', [hash, user.id]);
    // Sign out every other phone.
    await execute(
      conn,
      'UPDATE sessions SET revoked_at = CURRENT_TIMESTAMP(3) WHERE user_id = ? AND id <> ? AND revoked_at IS NULL',
      [user.id, user.sessionId],
    );
  });
}

export async function updateProfile(db: Db, user: AuthUser, displayName: string | null): Promise<ApiUser> {
  await execute(db, 'UPDATE users SET display_name = ? WHERE id = ?', [displayName?.trim() || null, user.id]);
  return toApiUser(await mustGetUser(db, user.id));
}

/**
 * Deletes the account. Private points go with it; public points stay on the
 * map for other drivers but no longer belong to anyone.
 */
export async function deleteAccount(db: Db, user: AuthUser): Promise<void> {
  await transaction(db, async (conn) => {
    const voted = await select<{ point_id: number }>(conn, 'SELECT point_id FROM point_votes WHERE user_id = ?', [user.id]);
    await execute(conn, "DELETE FROM points WHERE created_by = ? AND visibility = 'private'", [user.id]);
    await execute(conn, 'UPDATE points SET created_by = NULL, client_id = NULL WHERE created_by = ?', [user.id]);
    await execute(conn, 'DELETE FROM users WHERE id = ?', [user.id]);
    await recountPoints(conn, voted.map((v) => v.point_id));
  });
}

// ---- Settings backup ------------------------------------------------------

const MAX_SETTINGS_BYTES = 16 * 1024;

export async function getSettings(
  db: Db,
  user: AuthUser,
): Promise<{ settings: unknown; updatedAt: string | null }> {
  const row = await selectOne<{ settings: unknown; updated_at: Date }>(
    db,
    'SELECT settings, updated_at FROM user_settings WHERE user_id = ?',
    [user.id],
  );
  return { settings: row?.settings ?? null, updatedAt: row?.updated_at.toISOString() ?? null };
}

export async function saveSettings(
  db: Db,
  user: AuthUser,
  settings: Record<string, unknown>,
): Promise<{ updatedAt: string }> {
  const json = JSON.stringify(settings);
  if (Buffer.byteLength(json) > MAX_SETTINGS_BYTES) {
    throw badRequest('too_large', 'Settings are too large.');
  }
  try {
    await execute(
      db,
      `INSERT INTO user_settings (user_id, settings) VALUES (?, CAST(? AS JSON)) AS new
       ON DUPLICATE KEY UPDATE settings = new.settings`,
      [user.id, json],
    );
  } catch (e) {
    const code = (e as { code?: string }).code ?? '';
    if (code.startsWith('ER_JSON') || code.startsWith('ER_INVALID_JSON')) {
      throw badRequest('invalid_settings', 'These settings could not be saved.');
    }
    throw e;
  }
  const row = await selectOne<{ updated_at: Date }>(db, 'SELECT updated_at FROM user_settings WHERE user_id = ?', [user.id]);
  return { updatedAt: (row?.updated_at ?? new Date()).toISOString() };
}
