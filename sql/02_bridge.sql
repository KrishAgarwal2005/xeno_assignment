-- =====================================================================
-- THE RECONCILIATION BRIDGE, as one runnable query.
-- Run:  sqlite3 -box data/comm_log.db < sql/02_bridge.sql
--
-- Each row is a step in the order I actually discovered I needed it.
-- Steps 3-5 are WRONG models kept deliberately: the bridge is the record
-- of the investigation, not a tidied-up final answer.
-- =====================================================================

WITH RECURSIVE
sc AS (SELECT * FROM campaign WHERE merchant_id = 501),

fin AS (SELECT id FROM sc
        WHERE creation_status IN ('approved','aborted','resumed','stopped')
          AND processing_status = 'processed'),

climb(cid, n, np) AS (
    SELECT id, id, parent_id FROM sc
    UNION ALL
    SELECT cl.cid, p.id, p.parent_id FROM climb cl JOIN sc p ON p.id = cl.np),

root_of AS (SELECT cid, n AS root_id FROM climb WHERE np IS NULL),

standalone AS (
    SELECT c.id FROM sc c
    WHERE c.parent_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM sc ch WHERE ch.parent_id = c.id)),

qs AS (
    SELECT l.* FROM communication_log l
    JOIN fin f ON f.id = l.communication_id
    WHERE l.merchant_id = 501 AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'),

bridge(step, description, result, reason) AS (
  VALUES
  (0, 'Naive COUNT(*) over communication_log',
      (SELECT COUNT(*) FROM communication_log),
      'Starting point: assume one log row = one send.'),

  (1, 'Apply stated scope: merchant 501, Oct-2026, communication_type=2',
      (SELECT COUNT(*) FROM communication_log
       WHERE merchant_id = 501 AND communication_type = '2'
         AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01'),
      'No-op (-0). Verified rather than assumed: the whole extract is already in scope, so scope is not the gap.'),

  (2, 'Drop campaigns that have not cleared approval (9004)',
      (SELECT COUNT(*) FROM qs),
      '-4. Eligibility needs finalized creation_status AND processing_status=processed. 9004 is processed but approval_awaiting: the send pipeline ran ahead of sign-off.'),

  (3, 'Dedupe customers per CAMPAIGN (DISTINCT communication_id, customer_id)',
      (SELECT COUNT(*) FROM (SELECT DISTINCT communication_id, customer_id FROM qs)),
      '-1. First dedupe attempt. WRONG MODEL: treats each retry campaign as its own communication, so a retried customer still counts once per attempt.'),

  (4, 'Collapse retries one level: dedupe per COALESCE(parent_id, id)',
      (SELECT COUNT(*) FROM (SELECT DISTINCT COALESCE(c.parent_id, c.id) g, l.customer_id
                             FROM qs l JOIN sc c ON c.id = l.communication_id)),
      '-3. Hits 22 and matches Finance -- but I did not stop here: it is right by accident (two errors cancel). See steps 5 and 6.'),

  (5, 'Resolve chains RECURSIVELY to the true root (9003->9002->9001)',
      (SELECT COUNT(*) FROM (SELECT DISTINCT r.root_id, l.customer_id
                             FROM qs l JOIN root_of r ON r.cid = l.communication_id)),
      '-1, and it BREAKS the match. Correct fix though: one level of parent_id left 9003 in its own bucket, double-counting C3. Losing 22 here is what exposed the second error.'),

  (6, 'Stop deduping STANDALONE campaigns -- count their rows (9101)',
      (SELECT (SELECT COUNT(*) FROM (SELECT DISTINCT r.root_id, l.customer_id
                                     FROM qs l JOIN root_of r ON r.cid = l.communication_id
                                     WHERE l.communication_id NOT IN (SELECT id FROM standalone)))
            + (SELECT COUNT(*) FROM qs WHERE communication_id IN (SELECT id FROM standalone))),
      '+1. A standalone campaign is not a chain: every send is its own event, so C20 (re-targeted 10-Oct and 20-Oct under 9101) counts twice. Restores 22 for the right reason.')
)
SELECT step, description, result, reason FROM bridge ORDER BY step;
