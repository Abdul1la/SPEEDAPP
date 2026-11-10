import type { FastifyPluginAsync } from 'fastify';

import { requireRole } from '../auth/auth.ts';
import type { Role } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import * as admin from '../services/admin.ts';
import type { ReportAction } from '../services/admin.ts';
import type { PointInput, PointStatus } from '../services/points.ts';
import { idParams, pageQuery, pointFields } from './schemas.ts';

type IdParams = { id: string };
type PageQuery = { limit: number; offset: number };

/** Moderation API, used by the admin panel at /admin. */
export function adminRoutes({ db }: Deps): FastifyPluginAsync {
  return async (app) => {
    app.addHook('preHandler', requireRole(db, 'moderator'));

    app.get('/stats', async () => admin.stats(db));

    app.get<{ Querystring: PageQuery & { status: string } }>(
      '/reports',
      {
        schema: {
          querystring: {
            type: 'object',
            properties: {
              status: { type: 'string', enum: ['open', 'resolved', 'dismissed'], default: 'open' },
              ...pageQuery,
            },
          },
        },
      },
      async (request) => ({
        reports: await admin.listReports(db, request.query.status, request.query),
      }),
    );

    app.post<{ Params: IdParams; Body: { action: ReportAction; note?: string | null } }>(
      '/reports/:id/resolve',
      {
        schema: {
          params: idParams,
          body: {
            type: 'object',
            required: ['action'],
            additionalProperties: false,
            properties: {
              action: { type: 'string', enum: ['dismiss', 'keep_point', 'hide_point', 'remove_point'] },
              note: { type: ['string', 'null'], maxLength: 255 },
            },
          },
        },
      },
      async (request) =>
        admin.resolveReport(db, request.user!, Number(request.params.id), request.body.action, request.body.note ?? null),
    );

    app.get<{ Querystring: PageQuery & { status?: PointStatus; reported?: boolean; q?: string; ownerId?: number } }>(
      '/points',
      {
        schema: {
          querystring: {
            type: 'object',
            properties: {
              status: { type: 'string', enum: ['active', 'hidden', 'removed'] },
              reported: { type: 'boolean' },
              q: { type: 'string', maxLength: 100 },
              ownerId: { type: 'integer', minimum: 1 },
              ...pageQuery,
            },
          },
        },
      },
      async (request) => {
        const { limit, offset, ...filter } = request.query;
        return { points: await admin.listPoints(db, filter, { limit, offset }) };
      },
    );

    app.get<{ Params: IdParams }>('/points/:id', { schema: { params: idParams } }, async (request) =>
      admin.getAdminPoint(db, Number(request.params.id)),
    );

    app.patch<{ Params: IdParams; Body: PointInput & { status?: PointStatus } }>(
      '/points/:id',
      {
        schema: {
          params: idParams,
          body: {
            type: 'object',
            additionalProperties: false,
            minProperties: 1,
            properties: {
              ...pointFields,
              status: { type: 'string', enum: ['active', 'hidden', 'removed'] },
            },
          },
        },
      },
      async (request) => ({
        point: await admin.editPoint(db, request.user!, Number(request.params.id), request.body),
      }),
    );

    app.get<{ Querystring: PageQuery & { q?: string; status?: string; role?: string } }>(
      '/users',
      {
        schema: {
          querystring: {
            type: 'object',
            properties: {
              q: { type: 'string', maxLength: 100 },
              status: { type: 'string', enum: ['active', 'banned'] },
              role: { type: 'string', enum: ['user', 'moderator', 'admin'] },
              ...pageQuery,
            },
          },
        },
      },
      async (request) => {
        const { limit, offset, ...filter } = request.query;
        return { users: await admin.listUsers(db, filter, { limit, offset }) };
      },
    );

    app.get<{ Params: IdParams }>('/users/:id', { schema: { params: idParams } }, async (request) => ({
      user: await admin.getAdminUser(db, Number(request.params.id)),
    }));

    app.post<{ Params: IdParams; Body: { reason?: string | null; hidePoints?: boolean } }>(
      '/users/:id/ban',
      {
        schema: {
          params: idParams,
          body: {
            type: 'object',
            additionalProperties: false,
            properties: {
              reason: { type: ['string', 'null'], maxLength: 255 },
              hidePoints: { type: 'boolean', default: false },
            },
          },
        },
      },
      async (request) =>
        admin.banUser(
          db,
          request.user!,
          Number(request.params.id),
          request.body.reason?.trim() || null,
          request.body.hidePoints ?? false,
        ),
    );

    app.post<{ Params: IdParams }>('/users/:id/unban', { schema: { params: idParams } }, async (request) => ({
      user: await admin.unbanUser(db, request.user!, Number(request.params.id)),
    }));

    app.patch<{ Params: IdParams; Body: { role: Role } }>(
      '/users/:id',
      {
        schema: {
          params: idParams,
          body: {
            type: 'object',
            required: ['role'],
            additionalProperties: false,
            properties: { role: { type: 'string', enum: ['user', 'moderator', 'admin'] } },
          },
        },
      },
      async (request) => ({
        user: await admin.setRole(db, request.user!, Number(request.params.id), request.body.role),
      }),
    );

    app.get<{ Querystring: PageQuery }>(
      '/audit',
      { schema: { querystring: { type: 'object', properties: pageQuery } } },
      async (request) => ({ entries: await admin.listAudit(db, request.query) }),
    );
  };
}
