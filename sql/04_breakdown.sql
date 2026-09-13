-- =====================================================================
-- Audit trail: where does each unit of the 22 come from?
-- Run:  sqlite3 -box data/comm_log.db < sql/04_breakdown.sql
-- =====================================================================
WITH RECURSIVE
sc AS (SELECT * FROM campaign WHERE merchant_id = 501),
fin AS (SELECT id FROM sc WHERE creation_status IN ('approved','aborted','resumed','stopped')
                            AND processing_status = 'processed'),
climb(cid, n, np) AS (SELECT id, id, parent_id FROM sc
    UNION ALL SELECT cl.cid, p.id, p.parent_id FROM climb cl JOIN sc p ON p.id = cl.np),
root_of AS (SELECT cid, n AS root_id FROM climb WHERE np IS NULL),
standalone AS (SELECT c.id FROM sc c WHERE c.parent_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM sc ch WHERE ch.parent_id = c.id)),
qs AS (SELECT l.*, r.root_id FROM communication_log l
    JOIN fin f ON f.id = l.communication_id
    JOIN root_of r ON r.cid = l.communication_id
    WHERE l.merchant_id = 501 AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01')
SELECT root_id AS underlying_communication,
       CASE WHEN root_id IN (SELECT id FROM standalone)
            THEN 'standalone -> count rows'
            ELSE 'retry chain -> distinct customers' END AS rule,
       COUNT(*)                     AS raw_send_rows,
       COUNT(DISTINCT customer_id)  AS distinct_customers,
       CASE WHEN root_id IN (SELECT id FROM standalone)
            THEN COUNT(*) ELSE COUNT(DISTINCT customer_id) END AS contributes_to_target_base
FROM qs GROUP BY root_id
UNION ALL
SELECT 'TOTAL', '', SUM(raw), SUM(dis), SUM(contrib) FROM (
  SELECT COUNT(*) raw, COUNT(DISTINCT customer_id) dis,
         CASE WHEN root_id IN (SELECT id FROM standalone)
              THEN COUNT(*) ELSE COUNT(DISTINCT customer_id) END contrib
  FROM qs GROUP BY root_id);
