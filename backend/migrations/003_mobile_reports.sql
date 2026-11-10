-- Police radar: mobile speed cameras and police cars with a camera, which
-- move from day to day.
--  * Found automatically ('auto'): several drivers suddenly slowed down at
--    the same new spot (see `slowdowns`), or reported by a driver ('app').
--  * They leave the map by themselves (expires_at) unless drivers confirm
--    them, or slow down there again.
ALTER TABLE points
  MODIFY COLUMN type ENUM('camera', 'bump', 'mobile') NOT NULL,
  MODIFY COLUMN source ENUM('app', 'import', 'admin', 'auto') NOT NULL DEFAULT 'app',
  ADD COLUMN expires_at DATETIME(3) NULL
    COMMENT 'Temporary reports (police radar): gone from the map after this'
    AFTER status_reason,
  ADD COLUMN slowdown_count INT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Police radar: different drivers who suddenly slowed down here'
    AFTER report_count,
  ADD KEY ix_points_expires (expires_at);

-- A driver suddenly slowed down without stopping (the typical reaction to a
-- police radar). Only this spot is sent, never the route. Kept 14 days, to
-- tell a new radar from a place where drivers always brake (a junction).
CREATE TABLE slowdowns (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id      BIGINT UNSIGNED NOT NULL,
  lat          DECIMAL(9, 6)   NOT NULL,
  lng          DECIMAL(9, 6)   NOT NULL,
  location     POINT AS (
                 ST_PointFromText(CONCAT('POINT(', lng, ' ', lat, ')'), 4326, 'axis-order=long-lat')
               ) STORED NOT NULL SRID 4326,
  heading      SMALLINT UNSIGNED NULL COMMENT 'Travel direction (0 = north)',
  speed_before SMALLINT UNSIGNED NOT NULL COMMENT 'km/h before braking',
  speed_min    SMALLINT UNSIGNED NOT NULL COMMENT 'Lowest km/h, before speeding up again',
  point_id     BIGINT UNSIGNED  NULL COMMENT 'The police radar it was counted for',
  created_at   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  SPATIAL KEY sx_slowdowns_location (location),
  KEY ix_slowdowns_created (created_at),
  KEY ix_slowdowns_user (user_id, created_at),
  KEY ix_slowdowns_point (point_id),
  CONSTRAINT fk_slowdowns_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_slowdowns_point FOREIGN KEY (point_id) REFERENCES points (id) ON DELETE SET NULL,
  CONSTRAINT ck_slowdowns_heading CHECK (heading IS NULL OR heading < 360)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;
