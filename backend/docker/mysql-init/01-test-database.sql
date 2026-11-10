-- Runs once, when the MySQL container is first created.
-- A separate database for `npm test`, so tests never touch real data.
CREATE DATABASE IF NOT EXISTS speedalert_test CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL PRIVILEGES ON speedalert_test.* TO 'speedalert'@'%';
