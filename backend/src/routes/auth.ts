import type { FastifyPluginAsync } from 'fastify';

import { optionalUser, requireUser } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import * as users from '../services/users.ts';
import { credentialsBody, deviceName } from './schemas.ts';

/** Strict limit for sign-in endpoints (guessing passwords, mass sign-ups). */
const strict = {
  rateLimit: {
    max: 20,
    timeWindow: '1 minute',
    // Per IP, whatever headers are sent, so passwords can't be guessed fast.
    keyGenerator: (request: { ip: string }) => request.ip,
  },
};

export function authRoutes({ db }: Deps): FastifyPluginAsync {
  return async (app) => {
    // First start of the app: a driver account without email.
    app.post<{ Body: { deviceName?: string | null } }>(
      '/anonymous',
      {
        config: strict,
        schema: {
          body: {
            type: ['object', 'null'],
            additionalProperties: false,
            properties: { deviceName },
          },
        },
      },
      async (request, reply) => {
        const result = await users.createAnonymous(db, request.body?.deviceName ?? null);
        return reply.code(201).send(result);
      },
    );

    // Add email + password (keeps an anonymous driver's points).
    app.post<{ Body: { email: string; password: string; displayName?: string | null; deviceName?: string | null } }>(
      '/register',
      { config: strict, schema: { body: credentialsBody }, preHandler: optionalUser(db) },
      async (request, reply) => {
        const result = await users.register(db, request.user, request.body);
        return reply.code(201).send(result);
      },
    );

    // Sign in on a phone. An anonymous driver's points on this phone are
    // moved into the account.
    app.post<{ Body: { email: string; password: string; deviceName?: string | null } }>(
      '/login',
      { config: strict, schema: { body: credentialsBody }, preHandler: optionalUser(db) },
      async (request) => users.login(db, request.user, request.body),
    );

    app.post('/logout', { preHandler: requireUser(db) }, async (request, reply) => {
      await users.logout(db, request.user!);
      return reply.code(204).send();
    });

    app.post<{ Body: { currentPassword: string; newPassword: string } }>(
      '/password',
      {
        config: strict,
        preHandler: requireUser(db),
        schema: {
          body: {
            type: 'object',
            required: ['currentPassword', 'newPassword'],
            additionalProperties: false,
            properties: {
              currentPassword: { type: 'string', maxLength: 200 },
              newPassword: { type: 'string', maxLength: 200 },
            },
          },
        },
      },
      async (request, reply) => {
        await users.changePassword(db, request.user!, request.body);
        return reply.code(204).send();
      },
    );
  };
}
