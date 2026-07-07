#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read macOS call history (phone + FaceTime) from CallHistory.storedata.

Usage:
    uv run scripts/call_log.py recent [--limit N] [--since YYYY-MM-DD]
                                      [--contact SUBSTRING] [--json]
    uv run scripts/call_log.py last --contact SUBSTRING

Requires Full Disk Access for the terminal (TCC gates the CallHistoryDB dir).
"""

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

APPLE_EPOCH_OFFSET = 978307200  # 2001-01-01 00:00:00 UTC in unix time
DEFAULT_DB = (
    Path.home() / "Library" / "Application Support" / "CallHistoryDB"
    / "CallHistory.storedata"
)
# Values observed in the real DB (com.apple.Telephony / com.apple.FaceTime)
CALL_TYPES = {1: "phone", 8: "facetime-video", 16: "facetime-audio"}


def fetch_calls(db_path, limit=None, since=None, contact=None):
    """Return call dicts, newest first. `since` is YYYY-MM-DD (UTC)."""
    query = (
        "SELECT ZDATE, ZADDRESS, ZDURATION, ZANSWERED, ZORIGINATED, ZCALLTYPE"
        " FROM ZCALLRECORD WHERE 1=1"
    )
    params = []
    if since:
        dt = datetime.strptime(since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        query += " AND ZDATE >= ?"
        params.append(dt.timestamp() - APPLE_EPOCH_OFFSET)
    if contact:
        query += " AND ZADDRESS LIKE ?"
        params.append(f"%{contact}%")
    query += " ORDER BY ZDATE DESC"
    if limit:
        query += " LIMIT ?"
        params.append(limit)

    # ponytail: copy the store (+ sidecars) and open the copy read-only —
    # never touch the live Core Data store.
    with tempfile.TemporaryDirectory() as tmp:
        for suffix in ("", "-shm", "-wal"):
            src = Path(str(db_path) + suffix)
            if src.exists():
                shutil.copy2(src, Path(tmp) / src.name)
        copy = Path(tmp) / Path(db_path).name
        conn = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
        try:
            rows = conn.execute(query, params).fetchall()
        finally:
            conn.close()

    calls = []
    for zdate, address, duration, answered, originated, calltype in rows:
        unix_ts = int(zdate + APPLE_EPOCH_OFFSET)
        calls.append(
            {
                "date": datetime.fromtimestamp(unix_ts, tz=timezone.utc)
                .astimezone()
                .isoformat(),
                "timestamp": unix_ts,
                "address": address,
                "duration": round(duration or 0),
                "answered": bool(answered),
                "direction": "outgoing" if originated else "incoming",
                "type": CALL_TYPES.get(calltype, f"unknown({calltype})"),
            }
        )
    return calls


def print_table(calls):
    if not calls:
        print("No calls found.")
        return
    fmt = "{:<25} {:<18} {:<9} {:<8} {:<16} {:>6}"
    print(fmt.format("DATE", "ADDRESS", "DIR", "ANS", "TYPE", "SECS"))
    for c in calls:
        print(
            fmt.format(
                c["date"], c["address"] or "(unknown)", c["direction"],
                "yes" if c["answered"] else "no", c["type"], c["duration"],
            )
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    recent = sub.add_parser("recent", help="list recent calls, newest first")
    recent.add_argument("--limit", type=int, default=25)
    recent.add_argument("--since", help="YYYY-MM-DD (UTC)")
    recent.add_argument("--contact", help="substring match on handle/number")
    recent.add_argument("--json", action="store_true", dest="as_json")

    last = sub.add_parser("last", help="most recent call for a contact")
    last.add_argument("--contact", required=True)

    for p in (recent, last):
        p.add_argument("--db", type=Path, default=DEFAULT_DB)

    args = parser.parse_args(argv)
    if not args.db.exists():
        sys.exit(f"Call history DB not found: {args.db}")

    try:
        if args.command == "recent":
            calls = fetch_calls(
                args.db, limit=args.limit, since=args.since, contact=args.contact
            )
            if args.as_json:
                print(json.dumps(calls, indent=2))
            else:
                print_table(calls)
        else:
            calls = fetch_calls(args.db, limit=1, contact=args.contact)
            print_table(calls)
    except (sqlite3.OperationalError, PermissionError) as e:
        sys.exit(
            f"Could not read {args.db}: {e}\n"
            "If this is an authorization error, grant your terminal Full Disk"
            " Access (System Settings > Privacy & Security > Full Disk Access)."
        )


if __name__ == "__main__":
    main()
