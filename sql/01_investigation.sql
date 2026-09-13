-- =====================================================================
-- Q1-Q9: the profiling queries I ran BEFORE writing any count, in order.
-- Run:  sqlite3 -box data/comm_log.db < sql/01_investigation.sql
-- =====================================================================

.print '\n== Q1. How big is the problem? =='
SELECT (SELECT COUNT(*) FROM campaign)           AS campaigns,
       (SELECT COUNT(*) FROM communication_log)  AS log_rows;

.print '\n== Q2. Are the stated scope filters actually doing anything? =='
-- If these all come back as the full set, scope is NOT where the gap is.
SELECT COUNT(DISTINCT merchant_id)                                   AS merchants,
       COUNT(DISTINCT communication_type)                            AS types,
       MIN(sent_time) AS first_send, MAX(sent_time) AS last_send,
       SUM(sent_time <  '2026-10-01' OR sent_time >= '2026-11-01')   AS outside_october
FROM   communication_log;

.print '\n== Q3. Is every campaign a Diwali campaign? (scope says "all Diwali campaigns") =='
SELECT SUM(name NOT LIKE '%Diwali%') AS non_diwali_campaigns FROM campaign;

.print '\n== Q4. Referential integrity: any log row pointing at a missing campaign? =='
SELECT COUNT(*) AS orphan_log_rows
FROM   communication_log l LEFT JOIN campaign c ON c.id = l.communication_id
WHERE  c.id IS NULL;

.print '\n== Q5. The eligibility gate: which campaigns are reportable? =='
SELECT id, parent_id, creation_status, processing_status,
       CASE WHEN creation_status IN ('approved','aborted','resumed','stopped')
             AND processing_status = 'processed'
            THEN 'REPORTABLE' ELSE 'EXCLUDED' END AS verdict,
       name
FROM   campaign ORDER BY id;

.print '\n== Q6. Chain shape: how deep do retry chains go? =='
-- If max_depth > 2, a single COALESCE(parent_id, id) is not enough.
WITH RECURSIVE d(id, root, depth) AS (
    SELECT id, id, 1 FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, d.root, d.depth + 1 FROM campaign c JOIN d ON c.parent_id = d.id)
SELECT root AS chain_root, COUNT(*) AS campaigns_in_chain,
       MAX(depth) AS max_depth, GROUP_CONCAT(id) AS members
FROM   d GROUP BY root ORDER BY root;

.print '\n== Q7. Which campaigns are STANDALONE (no parent AND no children)? =='
SELECT c.id, c.name,
       CASE WHEN c.parent_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM campaign ch WHERE ch.parent_id = c.id)
            THEN 'STANDALONE -> count rows'
            ELSE 'IN A CHAIN -> count distinct customers' END AS counting_rule
FROM   campaign c ORDER BY c.id;

.print '\n== Q8. Where are the duplicate (campaign, customer) pairs? =='
-- These are the rows that any dedupe decision will hinge on.
SELECT communication_id, customer_id, COUNT(*) AS attempts,
       GROUP_CONCAT(sent_time, ' | ') AS times
FROM   communication_log GROUP BY 1,2 HAVING COUNT(*) > 1;

.print '\n== Q9. Which customers appear under MORE THAN ONE campaign? =='
-- Retried customers. Confirms the retry story in the data dictionary.
SELECT customer_id, COUNT(DISTINCT communication_id) AS campaigns_hit,
       GROUP_CONCAT(DISTINCT communication_id) AS which
FROM   communication_log GROUP BY 1 HAVING COUNT(DISTINCT communication_id) > 1;
