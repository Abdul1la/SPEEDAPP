import type { FastifyPluginAsync } from 'fastify';

import { requireUser } from '../auth/auth.ts';
import type { Deps } from '../app.ts';
import { badRequest } from '../lib/errors.ts';
import { planRoutes } from '../services/geo.ts';
import type { GeoProvider } from '../services/geo.ts';

const latLng = /^(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)$/;

function parseLatLng(value: string, name: string) {
  const m = latLng.exec(value.trim());
  const lat = Number(m?.[1]);
  const lng = Number(m?.[2]);
  if (!m || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw badRequest('invalid_request', `\`${name}\` must be "lat,lng".`);
  }
  return { lat, lng };
}

/** Place search and driving routes (with the cameras and bumps on them). */
export function geoRoutes({ db }: Deps, geo: GeoProvider): FastifyPluginAsync {
  return async (app) => {
    app.addHook('preHandler', requireUser(db));

    // Search as you type: "Duhok", a street, a shop...
    app.get<{ Querystring: { q: string; lat?: number; lng?: number; lang?: string } }>(
      '/places',
      {
        config: { rateLimit: { max: 120, timeWindow: '1 minute' } },
        schema: {
          querystring: {
            type: 'object',
            required: ['q'],
            properties: {
              q: { type: 'string', minLength: 1, maxLength: 120 },
              lat: { type: 'number', minimum: -90, maximum: 90 },
              lng: { type: 'number', minimum: -180, maximum: 180 },
              lang: { type: 'string', enum: ['en', 'default', 'de', 'fr'], default: 'en' },
            },
          },
        },
      },
      async (request) => {
        const { q, lat, lng, lang = 'en' } = request.query;
        const near = lat != null && lng != null ? { lat, lng } : null;
        return { places: await geo.search(q.trim(), near, lang) };
      },
    );

    // Ways to drive from `from` to `to`, fastest first.
    app.get<{ Querystring: { from: string; to: string } }>(
      '/routes',
      {
        config: { rateLimit: { max: 30, timeWindow: '1 minute' } },
        schema: {
          querystring: {
            type: 'object',
            required: ['from', 'to'],
            properties: {
              from: { type: 'string', maxLength: 60 },
              to: { type: 'string', maxLength: 60 },
            },
          },
        },
      },
      async (request) =>
        planRoutes(
          db,
          request.user!,
          geo,
          parseLatLng(request.query.from, 'from'),
          parseLatLng(request.query.to, 'to'),
        ),
    );
  };
}
