#!/usr/bin/env python3
"""
Minimal .sql runner so this repo works without the `sqlite3` CLI installed.

Mirrors `sqlite3 -box <db> < <file>` closely enough to read: it honours the
CLI's `.print` dot-command and renders each result set as a bordered table.

Usage: python3 tools/run_sql.py data/comm_log.db sql/02_bridge.sql
"""
import re
import sqlite3
import sys


def render(cur):
    if cur.description is None:
        return
    cols = [d[0] for d in cur.description]
    rows = [["" if v is None else str(v) for v in r] for r in cur.fetchall()]
    if not rows:
        print("(no rows)")
        return
    w = [max(len(cols[i]), max(len(r[i]) for r in rows)) for i in range(len(cols))]
    bar = "+" + "+".join("-" * (x + 2) for x in w) + "+"
    print(bar)
    print("| " + " | ".join(c.ljust(w[i]) for i, c in enumerate(cols)) + " |")
    print(bar)
    for r in rows:
        print("| " + " | ".join(r[i].ljust(w[i]) for i in range(len(cols))) + " |")
    print(bar)


def main(db, path):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    buf = ""
    for raw in open(path):
        line = raw.rstrip("\n")
        stripped = line.strip()
        # A dot-command is only a dot-command when no real SQL is pending.
        # Comments already in the buffer don't count as pending SQL.
        pending = re.sub(r"--[^\n]*", "", buf).strip()
        if not pending and stripped.startswith("."):
            if stripped.startswith(".print"):
                text = stripped[len(".print"):].strip().strip("'\"")
                print(text.replace("\\n", "\n"))
            continue
        buf += line + "\n"
        if sqlite3.complete_statement(buf):
            sql = buf.strip()
            buf = ""
            if sql.strip(";").strip():
                render(conn.execute(sql))
    if buf.strip():
        render(conn.execute(buf))
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: run_sql.py <db> <file.sql>")
    main(sys.argv[1], sys.argv[2])
