-- =====================================================================
-- FINAL ANSWER — target_base for merchant 501, October 2026 (Diwali)
-- Run:  sqlite3 data/comm_log.db < sql/03_target_base.sql
-- Expected output: 22
-- =====================================================================
--
-- Counting rule (from data/DATA_DICTIONARY.md):
--
--   target_base = "for a given underlying communication (a campaign plus
--   every retry chained off it), how many distinct customers were reached?"
--
-- That sentence contains two different counting rules, and the whole
-- exercise turns on applying each to the right campaign:
--
--   * RETRY CHAIN  -> one underlying communication spread over several
--                     campaign rows. Count DISTINCT customers in the chain:
--                     a customer who needed 3 attempts counts once.
--   * STANDALONE   -> a campaign with no parent and no children. Each send
--                     is its own event, so count ROWS - a customer
--                     re-targeted twice counts twice.
--
-- Eligibility gate: a campaign reaches official reporting only once its
-- creation workflow is finalized AND its send pipeline has finished.
-- The pipeline can run ahead of approval, so `processed` alone is not enough.
-- =====================================================================

WITH RECURSIVE
-- 0. Scope: this exercise is merchant 501 only.
scoped_campaign AS (
    SELECT id, parent_id, creation_status, processing_status
    FROM   campaign
    WHERE  merchant_id = 501
),

-- 1. Eligibility gate. 'approval_awaiting' has NOT cleared sign-off, so its
--    sends never reach reporting even though the pipeline already ran them.
finalized_campaign AS (
    SELECT id
    FROM   scoped_campaign
    WHERE  creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND  processing_status = 'processed'
),

-- 2. Walk every campaign UP its parent_id links to the root of its chain.
--    Recursion (not a single COALESCE(parent_id, id)) is required because
--    chains are deeper than two levels here: 9003 -> 9002 -> 9001.
--    Note we climb over ALL campaigns, not just finalized ones: chain
--    STRUCTURE is independent of approval state, so an unapproved campaign
--    can never silently detach its descendants from the real root.
climb(campaign_id, node_id, node_parent) AS (
    SELECT id, id, parent_id
    FROM   scoped_campaign
    UNION ALL
    SELECT cl.campaign_id, p.id, p.parent_id
    FROM   climb cl
    JOIN   scoped_campaign p ON p.id = cl.node_parent
),
root_of AS (
    SELECT campaign_id, node_id AS root_id
    FROM   climb
    WHERE  node_parent IS NULL          -- reached the top of the chain
),

-- 3. Standalone = points at nothing AND nothing points at it.
--    Structural test, deliberately ignoring status: a campaign whose only
--    child is still awaiting approval is a *parent*, not a standalone.
standalone AS (
    SELECT c.id
    FROM   scoped_campaign c
    WHERE  c.parent_id IS NULL
      AND  NOT EXISTS (SELECT 1 FROM scoped_campaign ch WHERE ch.parent_id = c.id)
),

-- 4. Send attempts that are in scope AND belong to a reportable campaign.
qualifying_send AS (
    SELECT l.id, l.customer_id, l.communication_id, r.root_id
    FROM   communication_log l
    JOIN   finalized_campaign f ON f.id = l.communication_id
    JOIN   root_of            r ON r.campaign_id = l.communication_id
    WHERE  l.merchant_id        = 501
      AND  l.communication_type = '2'                 -- Campaign
      AND  l.sent_time >= '2026-10-01'
      AND  l.sent_time <  '2026-11-01'
),

-- 5. Apply the two counting rules, then union the results.
countable AS (
    -- retry chains: collapse to one row per (chain, customer)
    SELECT root_id, customer_id
    FROM   qualifying_send
    WHERE  communication_id NOT IN (SELECT id FROM standalone)
    GROUP  BY root_id, customer_id

    UNION ALL

    -- standalone campaigns: every send attempt stands on its own
    SELECT root_id, customer_id
    FROM   qualifying_send
    WHERE  communication_id IN (SELECT id FROM standalone)
)

SELECT COUNT(*) AS target_base
FROM   countable;
