import type { FastifyReply, FastifyRequest } from 'fastify';

import { execute, selectOne } from '../db.ts';
import type { Db, Queryable } from '../db.ts';
import { forbidden, unauthorized } from '../lib/errors.ts';
import { hashToken, newToken } from './crypto.ts';

export type Role = 'user' | 'moderator' | 'admin';

/** The signed-in user of a request. */
export interface AuthUser {
  id: number;
  sessionId: number;
  email: string | null;
  displayName: string | null;
  role: Role;
  isAnonymous: boolean;
}

declare module 'fastify' {
  interface FastifyRequest {
    user: AuthUser | null;
  }
}

interface SessionRow {
  session_id: number;
  last_used_at: Date;
  user_id: number;
  email: string | null;
  display_name: string | null;
  role: Role;
  status: 'active' | 'banned';
  ban_reason: string | null;
}

const TOUCH_EVERY_MS = 60 * 60 * 1000;

function bearer(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  if (!header) return null;
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  return match?.[1] ?? null;
}

/**
 * Finds the user for the request's `Authorization: Bearer <token>` header.
 * Returns null without a header; throws for a bad token or a banned user.
 */
export async function userFromRequest(
  db: Db,
  request: FastifyRequest,
): Promise<AuthUser | null> {
  const token = bearer(request);
  if (!token) return null;
  const row = await selectOne<SessionRow>(
    db,
    `SELECT s.id AS session_id, s.last_used_at, u.id AS user_id, u.email,
            u.display_name, u.role, u.status, u.ban_reason
       FROM sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ? AND s.revoked_at IS NULL
        AND (s.expires_at IS NULL OR s.expires_at > CURRENT_TIMESTAMP(3))`,
    [hashToken(token)],
  );
  if (!row) throw unauthorized('Your sign-in has expired. Sign in again.');
  if (row.status === 'banned') {
    throw forbidden(
      'banned',
      row.ban_reason
        ? `This account is blocked: ${row.ban_reason}`
        : 'This account is blocked.',
    );
  }
  // Record activity at most once an hour (not on every request).
  if (Date.now() - row.last_used_at.getTime() > TOUCH_EVERY_MS) {
    void Promise.all([
      execute(db, 'UPDATE sessions SET last_used_at = CURRENT_TIMESTAMP(3) WHERE id = ?', [
        row.session_id,
      ]),
      execute(db, 'UPDATE users SET last_seen_at = CURRENT_TIMESTAMP(3) WHERE id = ?', [
        row.user_id,
      ]),
    ]).catch((e: unknown) => request.log.warn({ err: e }, 'Could not record activity'));
  }
  return {
    id: row.user_id,
    sessionId: row.session_id,
    email: row.email,
    displayName: row.display_name,
    role: row.role,
    isAnonymous: row.email == null,
  };
}

/** Route hook: the request must be signed in. */
export function requireUser(db: Db) {
  return async (request: FastifyRequest, _reply: FastifyReply) => {
    request.user = await userFromRequest(db, request);
    if (!request.user) throw unauthorized();
  };
}

/** Route hook: sign-in is optional (request.user may stay null). */
export function optionalUser(db: Db) {
  return async (request: FastifyRequest, _reply: FastifyReply) => {
    request.user = await userFromRequest(db, request);
  };
}

/** Creates a login session and returns its token (shown only this once). */
export async function createSession(
  db: Queryable,
  userId: number,
  deviceName: string | null,
  expiresInDays: number | null = null,
): Promise<string> {
  const token = newToken();
  await execute(
    db,
    `INSERT INTO sessions (user_id, token_hash, device_name, expires_at)
     VALUES (?, ?, ?, IF(? IS NULL, NULL, CURRENT_TIMESTAMP(3) + INTERVAL ? DAY))`,
    [userId, hashToken(token), deviceName, expiresInDays, expiresInDays],
  );
  return token;
}
