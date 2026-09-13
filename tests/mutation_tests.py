#!/usr/bin/env python3
"""
Mutation tests for the target_base reconciliation.

WHY THIS FILE EXISTS
--------------------
Three different queries return 22 against this dataset. Two of them are wrong
and land on 22 by luck. Matching the number is therefore NOT evidence that a
query is correct, so this harness perturbs the data in ways where the models
MUST disagree, and checks that only the recursive/standalone-aware model
tracks the hand-computed expectation.

    MINE     sql/03_target_base.sql  -- recursive chain root + standalone rule
    1-LEVEL  dedupe on COALESCE(parent_id, id)
    DELIV    count delivery_status = 900, no dedupe at all

Run:  python3 tests/mutation_tests.py
"""
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "comm_log.db"
FIN = ("creation_status IN ('approved','aborted','resumed','stopped') "
       "AND processing_status = 'processed'")

MINE = (ROOT / "sql" / "03_target_base.sql").read_text()

ONE_LEVEL = f"""
SELECT COUNT(*) FROM (
  SELECT DISTINCT COALESCE(c.parent_id, c.id) g, l.customer_id
  FROM communication_log l JOIN campaign c ON c.id = l.communication_id
  WHERE {FIN})"""

DELIVERED = f"""
SELECT COUNT(*) FROM communication_log l JOIN campaign c ON c.id = l.communication_id
WHERE {FIN} AND l.delivery_status = 900"""

INS = ("INSERT INTO communication_log VALUES"
       "(%d, 501, %d, '%s', '2', %d, '%s', '%s', 1, 'sms')")


def log(rid, camp, cust, status=900, when="2026-10-15 10:00:00"):
    return INS % (rid, camp, cust, status, when, when)


def evaluate(mutations):
    """Load a pristine copy into memory, apply mutations, run all 3 models."""
    disk = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    mem = sqlite3.connect(":memory:")
    disk.backup(mem)
    disk.close()
    for m in mutations:
        mem.execute(m)
    out = tuple(mem.execute(q).fetchone()[0] for q in (MINE, ONE_LEVEL, DELIVERED))
    mem.close()
    return out


CASES = [
    ("baseline - untouched dataset", [], 22,
     "All three models agree here. That agreement is the trap."),

    ("chain deepens to 4 levels (9005 under 9003), re-sends C3", [
        "INSERT INTO campaign VALUES (9005, 501, 9003, 'Retry D', 'approved', 'processed')",
        log(101, 9005, "C3")], 22,
     "C3 is already counted in chain 9001, so target_base must not move. "
     "1-LEVEL buckets 9005 under 9003 and invents a new communication."),

    ("standalone 9101 re-targets C20 a third time", [
        log(102, 9101, "C20")], 23,
     "Standalone sends are independent events, so this is a real +1. "
     "1-LEVEL dedupes it away and stays flat."),

    ("C3 never gets delivered (all 3 attempts fail)", [
        "UPDATE communication_log SET delivery_status = 1100 WHERE id = 6"], 22,
     "target_base counts customers targeted by the communication, not "
     "successful deliveries. DELIV drops C3 entirely."),

    ("C1 delivered twice inside chain 9001", [
        log(103, 9002, "C1")], 22,
     "A second delivery to an already-counted customer in the same chain "
     "adds nothing. DELIV counts it twice."),

    ("campaign 9004 finally clears approval", [
        "UPDATE campaign SET creation_status = 'approved' WHERE id = 9004"], 26,
     "C11-C14 become reportable and join chain 9001: +4. All models agree, "
     "which confirms the eligibility gate itself is not in dispute."),

    ("9004 clears approval, having also re-sent C2", [
        "UPDATE campaign SET creation_status = 'approved' WHERE id = 9004",
        log(104, 9004, "C2")], 26,
     "C2 already counted in chain 9001 via 9001/9002, so the extra row is "
     "absorbed. Guards the chain dedupe across a newly-eligible branch."),
]


def main():
    print(f"\n  Mutation tests -- {DB.relative_to(ROOT)}\n")
    print(f"  {'scenario':<56}{'expect':>7}{'MINE':>8}{'1-LEVEL':>9}{'DELIV':>7}")
    print("  " + "-" * 87)
    failures = 0
    divergences = 0
    for name, muts, expect, _rationale in CASES:
        mine, one, deliv = evaluate(muts)
        if mine != expect:
            failures += 1
        if one != expect or deliv != expect:
            divergences += 1
        mark = lambda v: f"{v}{'' if v == expect else ' X'}"
        print(f"  {name[:56]:<56}{expect:>7}{mark(mine):>8}{mark(one):>9}{mark(deliv):>7}")
    print("  " + "-" * 87)
    print(f"\n  MINE failed {failures} of {len(CASES)} cases.")
    print(f"  The two rival models were wrong in {divergences} of {len(CASES)} cases,")
    print("  yet all three return 22 on the untouched data.\n")
    if failures:
        print("  RESULT: FAIL\n")
        return 1
    print("  RESULT: PASS -- the final query holds up where the lucky ones break.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
