/** JSON schemas for request validation (Fastify rejects bad input with 400). */

export const idParams = {
  type: 'object',
  required: ['id'],
  properties: { id: { type: 'string', pattern: '^[1-9][0-9]{0,18}$' } },
} as const;

// Nullable fields use `type: [x, 'null']`, not anyOf: with anyOf, Fastify's
// type coercion turns null into 0 / "" before the 'null' branch is tried.
const nullableInt = (minimum: number, maximum: number) =>
  ({ type: ['integer', 'null'], minimum, maximum }) as const;

export const pointFields = {
  type: { type: 'string', enum: ['camera', 'bump', 'mobile'] },
  lat: { type: 'number', minimum: -90, maximum: 90 },
  lng: { type: 'number', minimum: -180, maximum: 180 },
  speedLimit: nullableInt(5, 300),
  direction: { type: ['number', 'null'], minimum: 0, maximum: 360 },
  note: { type: ['string', 'null'], maxLength: 200 },
  visibility: { type: 'string', enum: ['public', 'private'] },
} as const;

export const createPointBody = {
  type: 'object',
  required: ['type', 'lat', 'lng'],
  additionalProperties: false,
  properties: {
    ...pointFields,
    clientId: { type: 'string', pattern: '^[A-Za-z0-9_.:-]{1,64}$' },
  },
} as const;

export const updatePointBody = {
  type: 'object',
  additionalProperties: false,
  minProperties: 1,
  properties: pointFields,
} as const;

export const deviceName = { type: ['string', 'null'], maxLength: 100 } as const;

export const credentialsBody = {
  type: 'object',
  required: ['email', 'password'],
  additionalProperties: false,
  properties: {
    email: { type: 'string', minLength: 3, maxLength: 254 },
    password: { type: 'string', minLength: 1, maxLength: 200 },
    displayName: { type: ['string', 'null'], maxLength: 60 },
    deviceName,
  },
} as const;

export const pageQuery = {
  limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
  offset: { type: 'integer', minimum: 0, maximum: 1_000_000, default: 0 },
} as const;
