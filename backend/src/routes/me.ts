import type { FastifyPluginAsync } from 'fastify';

import { requireUser } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import { myPoints } from '../services/points.ts';
import * as users from '../services/users.ts';

/** The signed-in driver: profile, backup of points and settings, account deletion. */
export function meRoutes({ db }: Deps): FastifyPluginAsync {
  return async (app) => {
    app.addHook('preHandler', requireUser(db));

    app.get('/', async (request) => {
      const row = await users.getUser(db, request.user!.id);
      return { user: users.toApiUser(row!) };
    });

    app.patch<{ Body: { displayName: string | null } }>(
      '/',
      {
        schema: {
          body: {
            type: 'object',
            required: ['displayName'],
            additionalProperties: false,
            properties: { displayName: { type: ['string', 'null'], maxLength: 60 } },
          },
        },
      },
      async (request) => ({ user: await users.updateProfile(db, request.user!, request.body.displayName) }),
    );

    // Everything this driver added, public and private (restore on a new phone).
    app.get('/points', async (request) => ({ points: await myPoints(db, request.user!) }));

    app.get('/settings', async (request) => users.getSettings(db, request.user!));

    app.put<{ Body: { settings: Record<string, unknown> } }>(
      '/settings',
      {
        schema: {
          body: {
            type: 'object',
            required: ['settings'],
            additionalProperties: false,
            properties: { settings: { type: 'object' } },
          },
        },
      },
      async (request) => users.saveSettings(db, request.user!, request.body.settings),
    );

    // Required by the app stores: users must be able to delete their account.
    app.delete('/', async (request, reply) => {
      await users.deleteAccount(db, request.user!);
      return reply.code(204).send();
    });
  };
}
