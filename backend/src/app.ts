import rateLimit from '@fastify/rate-limit';
import Fastify from 'fastify';
import type { FastifyError, FastifyInstance, FastifyServerOptions } from 'fastify';

import type { Config } from './config.ts';
import { selectOne } from './db.ts';
import type { Db } from './db.ts';
import { ApiError } from './lib/errors.ts';
import { geoProvider } from './services/geo.ts';
import type { GeoProvider } from './services/geo.ts';
import { authRoutes } from './routes/auth.ts';
import { geoRoutes } from './routes/geo.ts';
import { meRoutes } from './routes/me.ts';
import { pointRoutes } from './routes/points.ts';
import { slowdownRoutes } from './routes/slowdowns.ts';

export interface Deps {
  db: Db;
  config: Config;
  /** Search and routing; OpenStreetMap services unless given (tests). */
  geo?: GeoProvider;
}

const TOKEN_HEADER = /^Bearer sa_[A-Za-z0-9_-]{43}$/;

/** Builds the HTTP API (without listening), so tests can call it directly. */
export async function buildApp(
  deps: Deps,
  logger: FastifyServerOptions['logger'] = { level: deps.config.logLevel },
): Promise<FastifyInstance> {
  const hops = deps.config.trustProxy;
  const app = Fastify({
    logger,
    // A number = trust only that many proxies in front of us (the client IP
    // is the next address in X-Forwarded-For, which clients can't fake).
    trustProxy: typeof hops === 'number' ? (_address: string, hop: number) => hop < hops : hops,
    bodyLimit: 64 * 1024,
  });
  app.decorateRequest('user', null);

  // Every error has the same shape: { "error": { "code", "message" } }.
  app.setErrorHandler((err: FastifyError | ApiError, request, reply) => {
    if (err instanceof ApiError) {
      return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    }
    if ((err as FastifyError).validation) {
      return reply.code(400).send({ error: { code: 'invalid_request', message: err.message } });
    }
    const status = (err as FastifyError).statusCode ?? 500;
    if (status < 500) {
      return reply
        .code(status)
        .send({ error: { code: (err as FastifyError).code ?? 'bad_request', message: err.message } });
    }
    request.log.error({ err }, 'Request failed');
    return reply.code(500).send({ error: { code: 'server_error', message: 'Something went wrong. Try again.' } });
  });
  app.setNotFoundHandler((request, reply) =>
    reply.code(404).send({ error: { code: 'not_found', message: `No route ${request.method} ${request.url}` } }),
  );

  // Per signed-in phone (or per IP before signing in). Routes can set
  // stricter limits with `config: { rateLimit: {...} }`.
  if (deps.config.rateLimit) {
    await app.register(rateLimit, {
      max: 600,
      timeWindow: '1 minute',
      // A made-up Authorization header must not give a fresh limit: only a
      // well-formed token counts, anything else is limited by IP.
      keyGenerator: (request) => {
        const auth = request.headers.authorization;
        return auth && TOKEN_HEADER.test(auth) ? auth : request.ip;
      },
      errorResponseBuilder: (_request, context) =>
        Object.assign(new ApiError(429, 'rate_limited', `Too many requests. Try again in ${context.after}.`), {
          statusCode: 429,
        }),
    });
  }

  app.get('/health', { config: { rateLimit: false } }, async () => {
    await selectOne(deps.db, 'SELECT 1 AS ok');
    return { ok: true };
  });

  await app.register(authRoutes(deps), { prefix: '/v1/auth' });
  await app.register(pointRoutes(deps), { prefix: '/v1/points' });
  await app.register(slowdownRoutes(deps), { prefix: '/v1/slowdowns' });
  await app.register(meRoutes(deps), { prefix: '/v1/me' });
  await app.register(geoRoutes(deps, deps.geo ?? geoProvider(deps.config)), { prefix: '/v1' });

  return app;
}
