-- When a public point was made private. Phones that downloaded it while it
-- was public learn to remove it, without the server revealing other
-- drivers' private points.
ALTER TABLE points
  ADD COLUMN unshared_at DATETIME(3) NULL
  COMMENT 'When a public point was made private'
  AFTER visibility;
