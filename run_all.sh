#!/usr/bin/env bash
# Runs every query and the mutation tests end to end.
# Uses the sqlite3 CLI when available, otherwise falls back to python3.
set -euo pipefail
cd "$(dirname "$0")"
DB=data/comm_log.db

if command -v sqlite3 >/dev/null 2>&1; then
  run() { sqlite3 -box "$DB" < "$1"; }
else
  echo "(sqlite3 CLI not found - using python3 fallback)"
  run() { python3 tools/run_sql.py "$DB" "$1"; }
fi

banner() { printf '\n\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..72})"; }

banner "1. INVESTIGATION - profiling queries, in the order they were run"
run sql/01_investigation.sql

banner "2. RECONCILIATION BRIDGE - 30 -> 22, wrong turns included"
run sql/02_bridge.sql

banner "3. FINAL ANSWER - target_base"
run sql/03_target_base.sql

banner "4. BREAKDOWN - where each unit of the 22 comes from"
run sql/04_breakdown.sql

banner "5. MUTATION TESTS - proving the query, not just the number"
python3 tests/mutation_tests.py
