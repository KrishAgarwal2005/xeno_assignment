# Investigation log

The narrative behind the bridge in the [README](../README.md): what I ran, in
what order, what broke, and what each break told me.

---

## Phase 0 — Read before querying

Two numbers were given: Finance says **22**; the log has **30** rows. Before
writing a count I wanted to know *what kind* of gap 8 sends could be. Three
candidate shapes:

1. **Scope** — rows in the file that are out of period / wrong merchant / wrong type.
2. **Eligibility** — campaigns present in the log that reporting excludes.
3. **Grain** — the log's grain (one send *attempt*) not matching the metric's
   grain (one *qualifying send*).

The data dictionary hints at all three, so I checked them in that order —
cheapest and most mechanical first.

---

## Phase 1 — Rule out scope (`sql/01_investigation.sql`, Q1–Q4)

```sql
SELECT COUNT(DISTINCT merchant_id), COUNT(DISTINCT communication_type),
       MIN(sent_time), MAX(sent_time),
       SUM(sent_time < '2026-10-01' OR sent_time >= '2026-11-01')
FROM communication_log;
```

One merchant (`501`), one type (`'2'`), sends from `2026-10-03` to
`2026-10-20`, zero rows outside October. All 7 campaigns are named `Diwali*`.
No orphan foreign keys.

**Every stated filter is a no-op.** Worth knowing rather than assuming: it
means the entire 8-send gap is structural, and it makes step 1 of the bridge a
deliberate `±0` rather than a missing step. I kept the filters in the final
query anyway — they encode the metric's definition and would matter the moment
this runs against the full table.

---

## Phase 2 — The eligibility gate (Q5) → **30 → 26**

The dictionary is explicit, and unusually specific about *why*:

> A campaign is included in official reporting only once both its creation
> workflow has cleared **and** its processing has completed […] the send
> pipeline can run ahead of approval bookkeeping catching up.

```sql
SELECT id, creation_status, processing_status FROM campaign;
```

All 7 campaigns are `processed`. Six are `approved`; **`9004` is
`approval_awaiting`**. The finalized set given is `approved`, `aborted`,
`resumed`, `stopped` — deliberately broader than "approved", so I coded the
set rather than `= 'approved'`. An `aborted` campaign still counts; an
unapproved one does not.

`9004` carries 4 sends (`C11`–`C14`), all `delivery_status = 900`. **−4 → 26.**

What makes this trap good: nothing in `communication_log` marks these rows.
They are delivered, timestamped, and billed. The exclusion is only visible by
joining to `campaign`.

---

## Phase 3 — First dedupe attempt → **26 → 25**

The dictionary says a customer can appear more than once against the same
`communication_id`, which reads like a double-count. So:

```sql
SELECT COUNT(*) FROM (SELECT DISTINCT communication_id, customer_id FROM ...);
```

**25.** Only −1 — it caught `C20` under `9101` and nothing else.

Not 22, and more importantly the model is wrong. It counts each *campaign*
as a communication, but the metric is defined over "a campaign **plus every
retry chained off it**". `C3` was sent under `9001`, `9002` and `9003` — three
campaigns, three counted rows, but the dictionary says that is **one**
underlying communication attempted three times.

Deduping on `communication_id` is deduping on the wrong key.

---

## Phase 4 — Collapse retries, one level → **26 → 22** (a false summit)

Group by the parent instead:

```sql
SELECT DISTINCT COALESCE(c.parent_id, c.id), l.customer_id ...
```

**22.** Matches Finance exactly.

I nearly stopped. Two things stopped me:

1. **Q6 said chains go three deep.** `9003.parent_id = 9002`, and
   `9002.parent_id = 9001`. `COALESCE(parent_id, id)` maps `9003 → 9002`, not
   `9003 → 9001`. The dictionary even warns: *"A chain can be more than two
   levels deep (A → B → C)."* My query provably mishandled a case the brief
   explicitly called out.
2. **The −8 didn't decompose cleanly.** I could account for −4 (approval) and
   the retry collapse, but when I wrote out the per-chain contributions the
   arithmetic only worked if `9101` was being deduped — and I had no
   justification for deduping it.

So the match was suspicious rather than reassuring.

---

## Phase 5 — Fix the chain walk → **22 → 21** (breaking it on purpose)

Replace the single `COALESCE` with a recursive climb to the true root:

```sql
climb(campaign_id, node_id, node_parent) AS (
    SELECT id, id, parent_id FROM scoped_campaign
    UNION ALL
    SELECT cl.campaign_id, p.id, p.parent_id
    FROM climb cl JOIN scoped_campaign p ON p.id = cl.node_parent)
```

Now `9003 → 9002 → 9001`, and `C3` collapses into chain `9001` once.

**21.** I had *lost* the match by fixing a real bug — which meant something
else was under-counting by 1, and step 4's 22 had been two errors cancelling.

This was the most useful moment in the exercise. A correct fix that breaks a
matching number is far more informative than a match, because it isolates the
remaining error to exactly one unit.

---

## Phase 6 — The standalone rule → **21 → 22**

Back to the dictionary, reading the last sentence properly this time:

> A campaign with no retry chain at all (no other campaign points at it, and
> it points at nothing) is a standalone communication — **every send under it
> is its own event, whether or not the same customer appears twice.**

`9101` has `parent_id IS NULL` and no children. It is standalone, so its 7
sends are 7 events. `C20` on 10-Oct and `C20` on 20-Oct are two separate
re-targets, not a duplicate to clean up.

The metric therefore uses **two different counting rules** depending on
campaign topology:

| Topology | Rule | Rationale |
|---|---|---|
| In a retry chain | `COUNT(DISTINCT customer_id)` per chain root | Retries are the *same* communication re-attempted. |
| Standalone | `COUNT(*)` rows | Independent re-targeting is a *new* communication event. |

`10 + 7 + 5 = 22`. ✅

---

## Phase 7 — Refusing to trust the number

Since I had already been fooled once, I checked how *many* wrong queries reach
22 on this data. Three do:

| Query | Result | Correct? |
|---|---:|---|
| Recursive chain dedupe + standalone rows | 22 | ✅ |
| One-level `COALESCE` dedupe | 22 | ❌ two cancelling errors |
| `COUNT(*) WHERE delivery_status = 900` | 22 | ❌ coincidence |

The third is the more seductive one: "22 = successful deliveries" is a clean
story. It holds only because in this extract every chain customer was
delivered exactly once and every standalone send succeeded. It is not the
definition — `target_base` counts customers *targeted*, and a customer who
failed all attempts still counts.

`tests/mutation_tests.py` encodes seven scenarios that pull the models apart:
a four-level chain, an extra standalone re-target, a never-delivered customer,
a twice-delivered customer, and `9004` clearing approval. Mine matches the
hand-computed expectation in all seven; the rivals fail five between them.

---

## Design decisions in the final query

**Climb the full `campaign` table, not just eligible ones.** Chain *structure*
is independent of approval state. If the walk were restricted to eligible
campaigns, an unapproved mid-chain campaign would sever its descendants from
the real root and silently split one communication into two. Eligibility is
applied when selecting which *log rows* to count, not when resolving topology.

**Test standalone structurally, ignoring status.** A campaign whose only child
is `approval_awaiting` is still a parent, not a standalone. Its sends should
be deduped against that child if the child later clears approval — mutation
test 7 covers exactly this.

**Half-open date range.** `sent_time >= '2026-10-01' AND < '2026-11-01'` rather
than `LIKE '2026-10%'` or `BETWEEN`, so a send at `2026-10-31 23:59:59` is
included and nothing at the boundary is lost. Text comparison is safe on this
`YYYY-MM-DD HH:MM:SS` format.

**`communication_type = '2'` as text.** The column is declared `text` and
stores `'2'`; SQLite would not coerce an integer `2` to match.

**`UNION ALL`, not `UNION`, for the final combine.** The two branches are
disjoint by construction, and `UNION` would silently collapse a legitimate
`(root, customer)` pair appearing in both — a bug waiting for the day the
partition assumption changes.

---

## If this ran in production

- **Reconcile credits against `target_base` separately.** `9004` burned 4
  credits that will never appear in `target_base`. Billing and reporting
  diverge here by design, and Finance should see both.
- **The `parent_id` walk needs a cycle guard at scale.** This extract is a
  clean forest, but a self-reference or loop would make the recursive CTE
  spin. A `depth < N` bound or visited-set is cheap insurance.
- **`COUNT(DISTINCT customer_id)` assumes a stable customer key.** If
  `customer_id` is ever remapped by an identity merge, chain dedupe silently
  changes. Worth pinning to a surrogate.
