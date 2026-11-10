import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import mysql from 'mysql2/promise';
import type { RowDataPacket } from 'mysql2/promise';

const MIGRATIONS_DIR = fileURLToPath(new URL('../migrations/', import.meta.url));

/**
 * Applies every `migrations/NNN_name.sql` file that hasn't run yet, in
 * order, and records it in `schema_migrations`. Safe to call on every
 * start: a lock stops two servers migrating at once.
 * Returns the names of the files that were applied.
 */
export async function runMigrations(
  databaseUrl: string,
  log: (message: string) => void = () => {},
): Promise<string[]> {
  const conn = await mysql.createConnection({
    uri: databaseUrl,
    multipleStatements: true,
    timezone: 'Z',
  });
  try {
    await conn.query("SET time_zone = '+00:00'");
    const [lock] = await conn.query<RowDataPacket[]>(
      "SELECT GET_LOCK('speedalert_migrations', 300) AS ok",
    );
    if (lock[0]?.ok !== 1) throw new Error('Could not get the migration lock');

    await conn.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    VARCHAR(255) NOT NULL PRIMARY KEY,
        applied_at DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
      ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4`);
    const [rows] = await conn.query<RowDataPacket[]>(
      'SELECT version FROM schema_migrations',
    );
    const done = new Set(rows.map((r) => r.version as string));

    const files = (await readdir(MIGRATIONS_DIR))
      .filter((f) => /^\d+_.+\.sql$/.test(f))
      .sort();
    const applied: string[] = [];
    for (const file of files) {
      if (done.has(file)) continue;
      log(`Applying migration ${file}`);
      const sql = await readFile(join(MIGRATIONS_DIR, file), 'utf8');
      await conn.query(sql);
      await conn.query('INSERT INTO schema_migrations (version) VALUES (?)', [file]);
      applied.push(file);
    }
    return applied;
  } finally {
    await conn.query("SELECT RELEASE_LOCK('speedalert_migrations')").catch(() => {});
    await conn.end();
  }
}
