# Speed Alert backend

Node.js (TypeScript, Fastify) API + MySQL 8.4 database for the Speed Alert app.

- **Community map**: points one driver adds are downloaded by every driver nearby.
- **Confirm / report**: "Still there" / "Gone" votes; wrong points hide themselves.
- **Backup & sync**: points and settings are saved to an account and come back on a new phone.
- **Admin moderation**: a web panel at `/admin` to review reports, edit points and ban users.

## Run it locally

You need Docker Desktop and Node.js 22.18+ (24 recommended).

```sh
cd backend
cp .env.example .env          # then change the passwords in .env
npm install
docker compose up -d db       # MySQL on 127.0.0.1:3306
npm run dev                   # API on http://localhost:3000 (restarts on changes)
```

The database tables are created automatically on start (`migrations/`).

Make yourself an admin, then open <http://localhost:3000/admin>:

```sh
npm run create-admin -- you@example.com "a long password"
```

Run the tests (they use the separate `speedalert_test` database, never your data):

```sh
npm test
npm run typecheck
```

## Load the cameras and bumps of a country (OpenStreetMap)

```sh
npm run import-osm -- --dry-run     # Iraq (IQ): only shows what would change
npm run import-osm                  # adds / updates them
npm run import-osm -- --prune       # also removes points deleted from OSM
npm run import-osm -- --country JO  # another country (ISO code)
```

It downloads every speed camera (`highway=speed_camera`, plus traffic
cameras on poles) and every speed bump (`traffic_calming=bump`, `hump`,
`cushion`, `table`...) from OpenStreetMap and adds them as community points
(`source = 'import'`, `client_id = 'osm:IQ:node/123'`). Run it again any
time (for example monthly): points imported before are updated, not
duplicated; points a driver already added are skipped; points that drivers
voted away or a moderator hid stay hidden.

- **Direction:** a camera on a one-way road gets that road's direction of
  travel. Otherwise OSM's `direction` tag is used; in Iraq it is the way the
  camera *looks* (it faces the traffic), so the travel direction is the
  opposite. The script checks this against the one-way roads and prints
  what it found.
- **Speed limit:** the camera's `maxspeed`, or the road's.
- **Public servers are often busy**: the script retries and tries other
  servers. `--save x.json` keeps the download, `--file x.json` reuses it.
- **License:** OpenStreetMap data is © OpenStreetMap contributors, under the
  [ODbL](https://www.openstreetmap.org/copyright). The app credits it in
  Settings; keep that credit.

On the server: `docker compose exec api node src/scripts/import-osm.ts`.

## Put it online

The simplest way is one small Linux server (VPS) with Docker:

```sh
git clone … && cd backend
cp .env.example .env    # set strong MYSQL_ROOT_PASSWORD and MYSQL_PASSWORD
docker compose up -d --build
docker compose exec api node src/scripts/create-admin.ts you@example.com "a long password"
```

Then put HTTPS in front of port 3000 (for example [Caddy](https://caddyserver.com):
`caddy reverse-proxy --from api.yourdomain.com --to localhost:3000`) and set
`TRUST_PROXY=true` in `.env`. The app must use `https://` in production.

### Better place search (Google Places)

Search works without any key, using OpenStreetMap. In Iraq OpenStreetMap
misses many places (for example residential projects like Lelav City, and
most shops and restaurants). For search as complete as Google Maps:

1. In [Google Cloud Console](https://console.cloud.google.com) (the project
   with the app's Maps key): **APIs & Services → Library → Places API (New) →
   Enable**.
2. **Credentials → Create credentials → API key**. Under *API restrictions*
   pick only **Places API (New)**. This is a server key: don't reuse the
   app's Android/iOS key.
3. Set it on the server: `GOOGLE_PLACES_KEY=...` (Railway: service →
   *Variables*; Docker: `.env`). Redeploy.

Then search uses Google (Iraq first, then the world) and falls back to
OpenStreetMap if Google fails; the server log says why
(`Google Places error 403: ...`). Google charges per use beyond a free
monthly amount. Each search costs one lookup when a result is picked
(typing in between is grouped into one session). Set a budget alert in
Google Cloud Billing.

**Backups:** `docker compose exec db mysqldump -uroot -p speedalert > backup.sql`
(run it daily, for example from cron, and keep copies off the server).

## Database

| Table | What it holds |
|---|---|
| `users` | Drivers (anonymous or with email + password) and staff (`role`: user / moderator / admin; `status`: active / banned). |
| `sessions` | Sign-in tokens (only a SHA-256 hash is stored). One per phone. |
| `points` | Cameras and bumps. `location` is a `POINT SRID 4326` calculated from `lat`/`lng` with a **spatial index** for fast "near me" queries. `visibility` public/private, `status` active/hidden/removed, vote and report counters. |
| `point_votes` | One "confirm" or "gone" vote per driver per point. |
| `point_reports` | Reports (fake, wrong place, wrong details, duplicate, other) for the moderation queue. |
| `user_settings` | Each driver's app settings (JSON). |
| `audit_log` | Every moderator / admin action. |
| `schema_migrations` | Which files in `migrations/` were applied. |

To change the database, add a new file such as `migrations/002_add_something.sql`.
It runs once, on the next start (or `npm run migrate`). Never edit a migration that already ran.

### Community rules (`src/services/points.ts`, `RULES`)

- A new public point of the same type within **25 m** (and a direction within
  45°, or "both ways") is the same point: it's counted as a confirmation instead
  of a duplicate.
- **3 "gone" votes**, more than its confirmations + 1, hide a point. Enough new
  confirmations bring it back.
- **3 open reports** from different drivers hide a point until a moderator
  reviews it.
- An owner deleting a point that others confirmed doesn't delete it for them:
  it becomes a community point and the owner's delete counts as "gone".
- Each driver can add at most `MAX_POINTS_PER_DAY` points a day (default 100).

### Police radar (`type: "mobile"`, `src/services/slowdowns.ts`)

Mobile speed cameras and police cars with a camera move from day to day, so
these points are temporary (`expiresAt`).

- **Found automatically:** the app sends `POST /v1/slowdowns` when its driver
  suddenly brakes on a fast road (from 50+ km/h, 20+ km/h slower, without
  stopping, then speeds up again; never braking for a turn). Only that spot
  is sent. When **3 different drivers** do this within **150 m**, the same
  way, within **90 minutes**, a police radar is added (`auto: true`). It is
  not added next to a known camera or bump (200 m), or at a spot where 2+
  drivers braked on 3 of the last 14 days (a junction or a bad road).
  Slowdowns are kept 14 days.
- **Reported by a driver:** `POST /v1/points` with `type: "mobile"`. A report
  within 100 m of an active one confirms it. Always public and both ways.
- **Lifetime:** 2 hours after the last report, confirmation or slowdown.
- **"Still there?":** the app asks drivers who pass one. 2 "gone" votes since
  the last confirmation hide it, however many confirmed it earlier; a new
  confirmation brings it back.
- Expired ones are left out of the map and routes, and sent as `removed` in
  delta syncs.

## API

All requests and responses are JSON. Send the token from sign-in as
`Authorization: Bearer <token>`. Errors look like
`{ "error": { "code": "not_owner", "message": "Only the driver who added this point can change it." } }`.

### Sign in

| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/v1/auth/anonymous` | `{ deviceName? }` | First start of the app. Returns `{ token, user }`. |
| POST | `/v1/auth/register` | `{ email, password, displayName?, deviceName? }` | With an anonymous token: upgrades that account (keeps its points). |
| POST | `/v1/auth/login` | `{ email, password, deviceName? }` | With an anonymous token: moves its points into the account. Returns `{ token, user, merged }`. |
| POST | `/v1/auth/logout` | | Signs out this phone. |
| POST | `/v1/auth/password` | `{ currentPassword, newPassword }` | Signs out the other phones. |

### Points

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/points?lat&lng&radiusKm=30&since=` | Points around a place (max 100 km). With `since` (the `serverTime` of the last answer): only changes, plus `removed` ids. Returns `{ points, removed, serverTime, truncated }`. |
| POST | `/v1/points` | `{ type, lat, lng, speedLimit?, direction?, note?, visibility?, clientId? }`. `201 { point, created: true }`, or `200 { point, merged: true }` when it matched an existing point. Same `clientId` again returns the first result (safe to retry). |
| GET | `/v1/points/:id` | |
| PATCH | `/v1/points/:id` | Owner only. Any point field; `null` clears it. |
| DELETE | `/v1/points/:id` | Owner only. `{ removed, kept }` (see rules). |
| PUT | `/v1/points/:id/vote` | `{ vote: "confirm" \| "gone" }` |
| POST | `/v1/slowdowns` | `{ lat, lng, heading?, speedBefore, speedMin }` (km/h). Returns `{ counted, radar }` (see Police radar). |
| DELETE | `/v1/points/:id/vote` | Take back your vote. |
| POST | `/v1/points/:id/reports` | `{ reason: "fake" \| "wrong_place" \| "wrong_details" \| "duplicate" \| "other", comment? }` |

A point: `{ id, type, lat, lng, speedLimit, direction, note, visibility, status,
confirmCount, goneCount, lastConfirmedAt, mine, myVote, clientId (owner only), createdAt, updatedAt }`.

### Search and directions

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/places?q&lat&lng&lang&session` | Search as you type, Iraq first. `{ places: [{ id, name, address, lat, lng, kind, distanceM? }], source: "google" \| "osm" }`. Google results have `lat`/`lng` null. |
| GET | `/v1/places/:id?session` | Where a result is (for Google ids `g:...`). Use the same `session` as the search. |
| GET | `/v1/routes?from=lat,lng&to=lat,lng` | Ways to drive there, fastest first, with cameras/bumps on each and turn-by-turn `steps`. |

### My account

| Method | Path | Notes |
|---|---|---|
| GET / PATCH | `/v1/me` | Profile (`{ displayName }`). |
| GET | `/v1/me/points` | Everything I added, including private points. |
| GET / PUT | `/v1/me/settings` | `{ settings: {...} }`, up to 16 KB. |
| DELETE | `/v1/me` | Deletes the account. Private points are deleted; public ones stay for other drivers. |

### Moderation (moderator or admin)

`GET /v1/admin/stats`, `GET /v1/admin/reports?status=open`,
`POST /v1/admin/reports/:id/resolve { action: dismiss | keep_point | hide_point | remove_point, note? }`,
`GET /v1/admin/points?status&reported&q&ownerId`, `GET|PATCH /v1/admin/points/:id`,
`GET /v1/admin/users?q&status&role`, `GET /v1/admin/users/:id`,
`POST /v1/admin/users/:id/ban { reason?, hidePoints? }`, `POST /v1/admin/users/:id/unban`,
`PATCH /v1/admin/users/:id { role }` (admin only), `GET /v1/admin/audit`.

## Code map

| Path | What |
|---|---|
| `migrations/` | Database tables (SQL). |
| `src/server.ts` | Starts the server. |
| `src/app.ts` | Routes, error format, rate limits, admin panel. |
| `src/routes/` | HTTP endpoints and input validation. |
| `src/services/` | The rules: `points.ts`, `users.ts`, `admin.ts`. |
| `src/auth/` | Tokens, passwords (scrypt), roles. |
| `admin/` | The admin web panel (plain HTML/JS). |
| `test/` | API tests against a real MySQL. |
