// npm run migrate — applies new files in migrations/ to DATABASE_URL.
import { loadConfig } from '../config.ts';
import { runMigrations } from '../migrate.ts';

const { databaseUrl } = loadConfig();
const applied = await runMigrations(databaseUrl, (m) => console.log(m));
console.log(applied.length ? `Done: ${applied.length} migration(s) applied.` : 'Database is up to date.');
