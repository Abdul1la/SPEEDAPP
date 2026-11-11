import { after, before, beforeEach } from 'node:test';

import type { FastifyInstance } from 'fastify';

import { buildApp } from '../src/app.ts';
import type { Config } from '../src/config.ts';
import { createPool, select } from '../src/db.ts';
import type { Db } from '../src/db.ts';
import { runMigrations } from '../src/migrate.ts';

export const TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL ?? 'mysql://speedalert:speedalert@127.0.0.1:3306/speedalert_test';

if (!/test/i.test(new URL(TEST_DATABASE_URL).pathname)) {
  throw new Error('TEST_DATABASE_URL must be a test database (its name must contain "test"): tests delete all data.');
}

export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    port: 0,
    host: '127.0.0.1',
    databaseUrl: TEST_DATABASE_URL,
    logLevel: 'silent',
    trustProxy: false,
    maxPointsPerDay: 100,
    migrateOnStart: false,
    rateLimit: false,
    photonUrl: 'http://127.0.0.1:9',
    osrmUrl: 'http://127.0.0.1:9',
    ...overrides,
  };
}

/** Drops every table, then runs all migrations from scratch. */
async function rebuildSchema(db: Db) {
  const tables = await select<{ name: string }>(
    db,
    'SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE()',
  );
  if (tables.length) {
    const conn = await db.getConnection();
    try {
      await conn.query('SET FOREIGN_KEY_CHECKS = 0');
      await conn.query(`DROP TABLE ${tables.map((t) => `\`${t.name}\``).join(', ')}`);
      await conn.query('SET FOREIGN_KEY_CHECKS = 1');
    } finally {
      conn.release();
    }
  }
  await runMigrations(TEST_DATABASE_URL);
}

const DATA_TABLES = [
  'audit_log',
  'user_settings',
  'slowdowns',
  'point_reports',
  'point_votes',
  'points',
  'sessions',
  'users',
];

async function emptyTables(db: Db) {
  const conn = await db.getConnection();
  try {
    await conn.query('SET FOREIGN_KEY_CHECKS = 0');
    for (const t of DATA_TABLES) await conn.query(`TRUNCATE TABLE ${t}`);
    await conn.query('SET FOREIGN_KEY_CHECKS = 1');
  } finally {
    conn.release();
  }
}

export interface TestContext {
  app: FastifyInstance;
  db: Db;
}

/** A fresh database for this test file, emptied before every test. */
export function useTestApp(overrides: Partial<Config> = {}): TestContext {
  const ctx = {} as TestContext;
  before(async () => {
    ctx.db = createPool(TEST_DATABASE_URL, 5);
    await rebuildSchema(ctx.db);
    ctx.app = await buildApp({ db: ctx.db, config: testConfig(overrides) }, false);
  });
  beforeEach(async () => {
    await emptyTables(ctx.db);
  });
  after(async () => {
    await ctx.app?.close();
    await ctx.db?.end();
  });
  return ctx;
}

export interface Res {
  status: number;
  /** Whatever JSON the API returned (tests read it freely). */
  body: any;
  headers: Record<string, unknown>;
}

export async function call(
  app: FastifyInstance,
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE',
  url: string,
  options: { token?: string | null; body?: unknown } = {},
): Promise<Res> {
  const res = await app.inject({
    method,
    url,
    headers: options.token ? { authorization: `Bearer ${options.token}` } : {},
    ...(options.body === undefined ? {} : { payload: options.body as object }),
  });
  let body: unknown = null;
  if (res.body) {
    try {
      body = res.json();
    } catch {
      body = res.body;
    }
  }
  return { status: res.statusCode, body, headers: res.headers };
}

/** A new anonymous driver; returns their token. */
export async function anonymous(app: FastifyInstance): Promise<string> {
  const res = await call(app, 'POST', '/v1/auth/anonymous', { body: { deviceName: 'test phone' } });
  if (res.status !== 201) throw new Error(`anonymous failed: ${JSON.stringify(res.body)}`);
  return res.body.token as string;
}

let emailCounter = 0;

/** A new driver with email + password; returns token and email. */
export async function registered(
  app: FastifyInstance,
  password = 'correct horse',
): Promise<{ token: string; email: string; id: string }> {
  const email = `driver${++emailCounter}@example.com`;
  const res = await call(app, 'POST', '/v1/auth/register', { body: { email, password } });
  if (res.status !== 201) throw new Error(`register failed: ${JSON.stringify(res.body)}`);
  return { token: res.body.token, email, id: res.body.user.id };
}

export const BAGHDAD = { lat: 33.3152, lng: 44.3661 };

/** A point [meters] north of [from]. */
export function north(from: { lat: number; lng: number }, meters: number) {
  return { lat: from.lat + meters / 111_320, lng: from.lng };
}

export async function addPoint(
  app: FastifyInstance,
  token: string,
  body: Record<string, unknown> = {},
): Promise<Res> {
  return call(app, 'POST', '/v1/points', {
    token,
    body: { type: 'camera', ...BAGHDAD, speedLimit: 80, ...body },
  });
}

export function nearbyUrl(at: { lat: number; lng: number }, extra = '') {
  return `/v1/points?lat=${at.lat}&lng=${at.lng}&radiusKm=5${extra}`;
}
