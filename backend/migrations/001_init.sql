-- Speed Alert database, version 1.
-- MySQL 8.4+, InnoDB, utf8mb4. All times are UTC with millisecond precision.

-- Drivers and staff. A driver starts anonymous (no email) so the app works
-- without signing up; adding an email + password turns it into a real
-- account that can be restored on a new phone.
CREATE TABLE users (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email         VARCHAR(254)    NULL,
  password_hash VARCHAR(255)    NULL,
  display_name  VARCHAR(60)     NULL,
  role          ENUM('user', 'moderator', 'admin') NOT NULL DEFAULT 'user',
  status        ENUM('active', 'banned')           NOT NULL DEFAULT 'active',
  ban_reason    VARCHAR(255)    NULL,
  created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  last_seen_at  DATETIME(3)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email),
  KEY ix_users_status (status),
  CONSTRAINT ck_users_login CHECK ((email IS NULL) = (password_hash IS NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Login tokens. Only a SHA-256 hash of each token is stored, so a database
-- leak doesn't leak working tokens.
CREATE TABLE sessions (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id      BIGINT UNSIGNED NOT NULL,
  token_hash   BINARY(32)      NOT NULL,
  device_name  VARCHAR(100)    NULL,
  created_at   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  last_used_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  expires_at   DATETIME(3)     NULL,
  revoked_at   DATETIME(3)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_token (token_hash),
  KEY ix_sessions_user (user_id),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Speed cameras and speed bumps.
--  * public points are shared with every driver; private ones only sync to
--    their owner's phones.
--  * status: active = shown; hidden = taken off the map by votes, reports
--    or a moderator (can come back); removed = deleted (kept as a tombstone
--    so phones learn to delete it).
--  * location is calculated from lat/lng and has a spatial index for fast
--    "points near me" queries.
CREATE TABLE points (
  id                BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  type              ENUM('camera', 'bump') NOT NULL,
  lat               DECIMAL(9, 6)    NOT NULL,
  lng               DECIMAL(9, 6)    NOT NULL,
  location          POINT AS (
                      ST_PointFromText(CONCAT('POINT(', lng, ' ', lat, ')'), 4326, 'axis-order=long-lat')
                    ) STORED NOT NULL SRID 4326,
  speed_limit       SMALLINT UNSIGNED NULL,
  direction         SMALLINT UNSIGNED NULL COMMENT 'Travel direction in degrees (0 = north). NULL = both ways.',
  note              VARCHAR(200)     NULL,
  visibility        ENUM('public', 'private') NOT NULL DEFAULT 'public',
  status            ENUM('active', 'hidden', 'removed') NOT NULL DEFAULT 'active',
  status_reason     ENUM('votes', 'reports', 'moderator', 'owner') NULL,
  confirm_count     INT UNSIGNED     NOT NULL DEFAULT 0,
  gone_count        INT UNSIGNED     NOT NULL DEFAULT 0,
  report_count      INT UNSIGNED     NOT NULL DEFAULT 0 COMMENT 'Open reports',
  last_confirmed_at DATETIME(3)      NULL,
  created_by        BIGINT UNSIGNED  NULL COMMENT 'NULL = owned by the community',
  client_id         VARCHAR(64)      NULL COMMENT 'Id made by the phone; makes uploads safe to retry',
  source            ENUM('app', 'import', 'admin') NOT NULL DEFAULT 'app',
  created_at        DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at        DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  SPATIAL KEY sx_points_location (location),
  UNIQUE KEY uq_points_client (created_by, client_id),
  KEY ix_points_owner (created_by, status),
  KEY ix_points_status (status, updated_at),
  KEY ix_points_updated (updated_at),
  CONSTRAINT fk_points_owner FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT ck_points_lat CHECK (lat BETWEEN -90 AND 90),
  CONSTRAINT ck_points_lng CHECK (lng BETWEEN -180 AND 180),
  CONSTRAINT ck_points_direction CHECK (direction IS NULL OR direction < 360),
  CONSTRAINT ck_points_limit CHECK (speed_limit IS NULL OR speed_limit BETWEEN 5 AND 300)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- "Still there" / "Gone" votes. One per driver per point (can be changed).
CREATE TABLE point_votes (
  point_id   BIGINT UNSIGNED NOT NULL,
  user_id    BIGINT UNSIGNED NOT NULL,
  vote       ENUM('confirm', 'gone') NOT NULL,
  created_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (point_id, user_id),
  KEY ix_votes_user (user_id),
  CONSTRAINT fk_votes_point FOREIGN KEY (point_id) REFERENCES points (id) ON DELETE CASCADE,
  CONSTRAINT fk_votes_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Reports of fake / wrong / duplicate points, for the moderation queue.
CREATE TABLE point_reports (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  point_id        BIGINT UNSIGNED NOT NULL,
  user_id         BIGINT UNSIGNED NULL,
  reason          ENUM('fake', 'wrong_place', 'wrong_details', 'duplicate', 'other') NOT NULL,
  comment         VARCHAR(500)    NULL,
  status          ENUM('open', 'resolved', 'dismissed') NOT NULL DEFAULT 'open',
  resolved_by     BIGINT UNSIGNED NULL,
  resolved_at     DATETIME(3)     NULL,
  resolution_note VARCHAR(255)    NULL,
  created_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY ix_reports_status (status, created_at),
  KEY ix_reports_point (point_id, status),
  KEY ix_reports_user (user_id),
  CONSTRAINT fk_reports_point FOREIGN KEY (point_id) REFERENCES points (id) ON DELETE CASCADE,
  CONSTRAINT fk_reports_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_reports_resolver FOREIGN KEY (resolved_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Backed-up app settings (warning distances, repeats, map look...).
CREATE TABLE user_settings (
  user_id    BIGINT UNSIGNED NOT NULL,
  settings   JSON            NOT NULL,
  updated_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (user_id),
  CONSTRAINT fk_settings_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Every moderator / admin action, for accountability.
CREATE TABLE audit_log (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  actor_id    BIGINT UNSIGNED NULL,
  action      VARCHAR(40)     NOT NULL,
  target_type ENUM('point', 'user', 'report') NOT NULL,
  target_id   BIGINT UNSIGNED NOT NULL,
  details     JSON            NULL,
  created_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY ix_audit_target (target_type, target_id),
  KEY ix_audit_created (created_at),
  CONSTRAINT fk_audit_actor FOREIGN KEY (actor_id) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;
