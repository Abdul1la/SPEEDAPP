import type { FastifyPluginAsync } from 'fastify';

import { requireUser } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import { addSlowdown } from '../services/slowdowns.ts';
import type { SlowdownInput } from '../services/slowdowns.ts';

/** POST /v1/slowdowns: a driver suddenly slowed down (see services/slowdowns.ts). */
export function slowdownRoutes({ db }: Deps): FastifyPluginAsync {
  return async (app) => {
    app.addHook('preHandler', requireUser(db));

    app.post<{ Body: SlowdownInput }>(
      '/',
      {
        schema: {
          body: {
            type: 'object',
            required: ['lat', 'lng', 'speedBefore', 'speedMin'],
            additionalProperties: false,
            properties: {
              lat: { type: 'number', minimum: -90, maximum: 90 },
              lng: { type: 'number', minimum: -180, maximum: 180 },
              heading: { type: ['number', 'null'], minimum: 0, maximum: 360 },
              speedBefore: { type: 'number', minimum: 0, maximum: 400 },
              speedMin: { type: 'number', minimum: 0, maximum: 400 },
            },
          },
        },
      },
      async (request) => addSlowdown(db, request.user!, request.body),
    );
  };
}
