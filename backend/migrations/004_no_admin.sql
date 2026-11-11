-- The admin panel and "Report a problem" were removed, so nobody reviews
-- reports any more. Points that reports had hidden come back on the map
-- (drivers' "Gone" votes still take wrong points off), and open reports are
-- closed. The tables stay, so old data isn't lost.
UPDATE points SET status = 'active', status_reason = NULL
 WHERE status = 'hidden' AND status_reason = 'reports';

UPDATE points SET report_count = 0 WHERE report_count > 0;

UPDATE point_reports
   SET status = 'dismissed', resolved_at = CURRENT_TIMESTAMP(3),
       resolution_note = 'Admin panel removed'
 WHERE status = 'open';
