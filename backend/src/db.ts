import mysql from 'mysql2/promise';
import type {
  Pool,
  PoolConnection,
  ResultSetHeader,
  RowDataPacket,
} from 'mysql2/promise';

export type Db = Pool;
/** A pool or a connection inside a transaction: both can run queries. */
export type Queryable = Pool | PoolConnection;
export type Params = ReadonlyArray<unknown>;

export function createPool(url: string, connectionLimit = 10): Pool {
  const pool = mysql.createPool({
    uri: url,
    connectionLimit,
    charset: 'utf8mb4',
    // DECIMAL columns (lat, lng) as numbers, BIGINT ids as numbers.
    decimalNumbers: true,
    supportBigNumbers: true,
    // JS Dates are read and written as UTC...
    timezone: 'Z',
  });
  // ...and so is everything MySQL itself stamps (CURRENT_TIMESTAMP).
  pool.pool.on('connection', (conn) => {
    conn.query("SET time_zone = '+00:00'");
  });
  return pool;
}

/** Runs a SELECT and returns its rows. */
export async function select<T>(
  db: Queryable,
  sql: string,
  params: Params = [],
): Promise<T[]> {
  const [rows] = await db.query<RowDataPacket[]>(sql, params as unknown[]);
  return rows as unknown as T[];
}

/** Runs a SELECT and returns the first row, or undefined. */
export async function selectOne<T>(
  db: Queryable,
  sql: string,
  params: Params = [],
): Promise<T | undefined> {
  const rows = await select<T>(db, sql, params);
  return rows[0];
}

/** Runs an INSERT / UPDATE / DELETE. */
export async function execute(
  db: Queryable,
  sql: string,
  params: Params = [],
): Promise<ResultSetHeader> {
  const [result] = await db.query<ResultSetHeader>(sql, params as unknown[]);
  return result;
}

/** Runs [fn] in a transaction: commits if it returns, rolls back if it throws. */
export async function transaction<T>(
  db: Pool,
  fn: (conn: PoolConnection) => Promise<T>,
): Promise<T> {
  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    const result = await fn(conn);
    await conn.commit();
    return result;
  } catch (e) {
    await conn.rollback().catch(() => {});
    throw e;
  } finally {
    conn.release();
  }
}
