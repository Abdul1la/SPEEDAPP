export interface Config {
  port: number;
  host: string;
  databaseUrl: string;
  logLevel: string;
  /** Behind a reverse proxy: how many proxies to trust (a number), so client
   * IPs for rate limits are right and can't be faked. false = none. */
  trustProxy: boolean | number;
  /** Most points one driver can add in 24 hours. */
  maxPointsPerDay: number;
  /** Run database migrations when the server starts. */
  migrateOnStart: boolean;
  /** Limit requests per phone / IP (turn off only for tests). */
  rateLimit: boolean;
}

function int(value: string | undefined, fallback: number): number {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
}

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value == null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

/** TRUST_PROXY=1 (hops) is safest; "true" trusts every hop (spoofable). On
 * Railway, which runs the app behind one proxy, the default is 1. */
function proxyHops(env: NodeJS.ProcessEnv): boolean | number {
  const v = env.TRUST_PROXY?.trim();
  if (v && /^\d+$/.test(v)) return Number(v);
  if (v) return bool(v, false);
  return env.RAILWAY_ENVIRONMENT || env.RAILWAY_ENVIRONMENT_NAME ? 1 : false;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const databaseUrl = env.DATABASE_URL;
  if (!databaseUrl) {
    throw new Error(
      'DATABASE_URL is not set. Copy .env.example to .env (see README.md).',
    );
  }
  return {
    port: int(env.PORT, 3000),
    host: env.HOST ?? '0.0.0.0',
    databaseUrl,
    logLevel: env.LOG_LEVEL ?? 'info',
    trustProxy: proxyHops(env),
    maxPointsPerDay: int(env.MAX_POINTS_PER_DAY, 100),
    migrateOnStart: bool(env.MIGRATE_ON_START, true),
    rateLimit: bool(env.RATE_LIMIT, true),
  };
}
