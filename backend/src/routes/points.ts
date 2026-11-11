import type { FastifyPluginAsync } from 'fastify';

import { requireUser } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import { badRequest } from '../lib/errors.ts';
import * as points from '../services/points.ts';
import type { PointInput, PointType, Vote } from '../services/points.ts';
import { createPointBody, idParams, updatePointBody } from './schemas.ts';

type IdParams = { id: string };

export function pointRoutes({ db, config }: Deps): FastifyPluginAsync {
  return async (app) => {
    app.addHook('preHandler', requireUser(db));

    // Points near a place. With `since`, only what changed (for syncing).
    app.get<{ Querystring: { lat: number; lng: number; radiusKm?: number; since?: string } }>(
      '/',
      {
        schema: {
          querystring: {
            type: 'object',
            required: ['lat', 'lng'],
            properties: {
              lat: { type: 'number', minimum: -90, maximum: 90 },
              lng: { type: 'number', minimum: -180, maximum: 180 },
              radiusKm: { type: 'number', exclusiveMinimum: 0, maximum: 100, default: 30 },
              since: { type: 'string', format: 'date-time' },
            },
          },
        },
      },
      async (request) => {
        const { lat, lng, radiusKm = 30, since } = request.query;
        const sinceDate = since ? new Date(since) : null;
        if (sinceDate && Number.isNaN(sinceDate.getTime())) {
          throw badRequest('invalid_request', '`since` must be a date.');
        }
        return points.nearby(db, request.user!, { lat, lng, radiusM: radiusKm * 1000, since: sinceDate });
      },
    );

    app.post<{ Body: PointInput & { type: PointType; lat: number; lng: number } }>(
      '/',
      { schema: { body: createPointBody } },
      async (request, reply) => {
        const result = await points.createPoint(db, request.user!, request.body, config.maxPointsPerDay);
        return reply.code(result.created ? 201 : 200).send(result);
      },
    );

    app.get<{ Params: IdParams }>('/:id', { schema: { params: idParams } }, async (request) => ({
      point: await points.getPoint(db, request.user!, Number(request.params.id)),
    }));

    app.patch<{ Params: IdParams; Body: PointInput }>(
      '/:id',
      { schema: { params: idParams, body: updatePointBody } },
      async (request) => ({
        point: await points.updatePoint(db, request.user!, Number(request.params.id), request.body),
      }),
    );

    app.delete<{ Params: IdParams }>('/:id', { schema: { params: idParams } }, async (request) =>
      points.deletePoint(db, request.user!, Number(request.params.id)),
    );

    // "Still there" / "Gone".
    app.put<{ Params: IdParams; Body: { vote: Vote } }>(
      '/:id/vote',
      {
        schema: {
          params: idParams,
          body: {
            type: 'object',
            required: ['vote'],
            additionalProperties: false,
            properties: { vote: { type: 'string', enum: ['confirm', 'gone'] } },
          },
        },
      },
      async (request) => ({
        point: await points.votePoint(db, request.user!, Number(request.params.id), request.body.vote),
      }),
    );

    app.delete<{ Params: IdParams }>('/:id/vote', { schema: { params: idParams } }, async (request) => ({
      point: await points.unvotePoint(db, request.user!, Number(request.params.id)),
    }));
  };
}
