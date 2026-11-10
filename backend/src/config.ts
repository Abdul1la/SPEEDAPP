export interface Config {
  port: number;
  host: string;
  databaseUrl: string;
  logLevel: string;
  /** True behind a reverse proxy, so client IPs (for rate limits) are right. */
  trustProxy: boolean;
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
    trustProxy: bool(env.TRUST_PROXY, false),
    maxPointsPerDay: int(env.MAX_POINTS_PER_DAY, 100),
    migrateOnStart: bool(env.MIGRATE_ON_START, true),
    rateLimit: bool(env.RATE_LIMIT, true),
  };
}
