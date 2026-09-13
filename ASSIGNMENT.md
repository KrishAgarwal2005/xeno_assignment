# Scope

Take-home brief, in one line: **Finance reports a `target_base` of 22** for
merchant 501, October 2026, across all Diwali campaigns
(`communication_type = '2'`). Reproduce that number from the raw data and
explain the gap between it and a straightforward query.

Deliverables asked for: a reconciliation bridge from the naive query to the
final number with a reason per adjustment, the SQL that computes it, and a
short note on anything surprising in the data.

The dataset itself is included under [`data/`](data/) so every query here is
runnable as-is. The brief document and the dataset generator that shipped
alongside it are deliberately **not** reproduced — the generator in particular
spells out the intended construction, and publishing it would give the
exercise away.

| Required | Location |
|---|---|
| Reconciliation bridge | [`README.md`](README.md#the-reconciliation-bridge) · runnable: [`sql/02_bridge.sql`](sql/02_bridge.sql) |
| Final SQL | [`sql/03_target_base.sql`](sql/03_target_base.sql) |
| What surprised me | [`README.md`](README.md#what-surprised-me) |
| How I investigated | [`docs/INVESTIGATION.md`](docs/INVESTIGATION.md) |
