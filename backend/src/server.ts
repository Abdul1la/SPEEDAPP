import { buildApp } from './app.ts';
import { loadConfig } from './config.ts';
import { createPool } from './db.ts';
import { runMigrations } from './migrate.ts';

const config = loadConfig();

if (config.migrateOnStart) {
  const applied = await runMigrations(config.databaseUrl, (m) => console.log(m));
  if (applied.length) console.log(`Database updated (${applied.length} migration(s)).`);
}

const db = createPool(config.databaseUrl);
const app = await buildApp({ db, config });

let closing = false;
async function shutdown(signal: string) {
  if (closing) return;
  closing = true;
  app.log.info(`${signal} received, shutting down`);
  await app.close();
  await db.end();
  process.exit(0);
}
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

await app.listen({ port: config.port, host: config.host });
