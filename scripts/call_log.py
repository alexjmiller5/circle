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
    uv run scripts/call_log.py coverage

Requires Full Disk Access for the terminal (TCC gates the CallHistoryDB dir).
"""

import argparse
import json
import hashlib
import math
import sqlite3
import sys
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
    """Read one SQLite snapshot. IDs are scoped to the source store, not a person."""
    if limit is not None and (not isinstance(limit, int) or limit < 1):
        raise ValueError("limit must be a positive integer")
    conn = sqlite3.connect(Path(db_path).resolve().as_uri() + "?mode=ro", uri=True)
    try:
        conn.execute("PRAGMA query_only=ON")
        conn.execute("BEGIN")
        columns = {row[1] for row in conn.execute("PRAGMA table_info(ZCALLRECORD)")}
        required = {"Z_PK", "ZDATE", "ZADDRESS", "ZDURATION", "ZANSWERED", "ZORIGINATED", "ZCALLTYPE"}
        if not required <= columns:
            raise ValueError("Unsupported call history schema")
        try:
            metadata = conn.execute("SELECT Z_UUID FROM Z_METADATA").fetchall()
        except sqlite3.OperationalError as exc:
            raise ValueError("Missing source store identity") from exc
        if len(metadata) != 1 or not metadata[0][0]:
            raise ValueError("Missing or ambiguous source store identity")
        namespace = hashlib.sha256(str(metadata[0][0]).encode()).hexdigest()
        optional = [name if name in columns else "NULL" for name in ("ZUNIQUE_ID", "ZSERVICE_PROVIDER")]
        query = "SELECT Z_PK,ZDATE,ZADDRESS,ZDURATION,ZANSWERED,ZORIGINATED,ZCALLTYPE," + ",".join(optional) + " FROM ZCALLRECORD WHERE 1=1"
        params = []
        if since:
            dt = datetime.strptime(since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            query += " AND ZDATE >= ?"
            params.append(dt.timestamp() - APPLE_EPOCH_OFFSET)
        if contact:
            query += " AND instr(lower(ZADDRESS),lower(?)) > 0"
            params.append(contact)
        query += " ORDER BY ZDATE DESC, Z_PK DESC"
        if limit is not None:
            query += " LIMIT ?"
            params.append(limit)
        rows = conn.execute(query, params).fetchall()
    finally:
        conn.close()

    calls = []
    for pk, zdate, address, duration, answered, originated, calltype, native_id, provider in rows:
        if not isinstance(zdate, (float, int)) or not math.isfinite(zdate):
            raise ValueError("Invalid source event timestamp; history cannot be treated as complete")
        unix_ts = zdate + APPLE_EPOCH_OFFSET
        calls.append({
            "source_id": str(native_id) if native_id else str(pk),
            "source_namespace": namespace,
            "identity_kind": "native" if native_id else "store_local",
            "service_provider": provider,
            "date": datetime.fromtimestamp(unix_ts, tz=timezone.utc).isoformat(),
            "timestamp": unix_ts,
            "address": address,
            "duration": duration,
            "answered": {0: False, 1: True}.get(answered),
            "direction": {0: "incoming", 1: "outgoing"}.get(originated, "unknown"),
            "type": CALL_TYPES.get(calltype, f"unknown({calltype})"),
        })
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
                {True: "yes", False: "no", None: "unknown"}[c["answered"]],
                c["type"], c["duration"] if c["duration"] is not None else "?",
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

    coverage = sub.add_parser("coverage", help="observed inventory, never proof of full history")

    for p in (recent, last, coverage):
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
        elif args.command == "coverage":
            calls = fetch_calls(args.db)
            print(json.dumps({
                "observed_rows": len(calls),
                "oldest_timestamp": min((c["timestamp"] for c in calls), default=None),
                "newest_timestamp": max((c["timestamp"] for c in calls), default=None),
                "native_identity_rows": sum(c["identity_kind"] == "native" for c in calls),
                "store_local_identity_rows": sum(c["identity_kind"] == "store_local" for c in calls),
                "history_complete": False,
                "participant_completeness": "unknown",
                "reason": "Inventory of the available local store; retention, sync and participant coverage are not proven.",
            }, indent=2))
        else:
            calls = fetch_calls(args.db, limit=1, contact=args.contact)
            print_table(calls)
    except (sqlite3.Error, PermissionError, ValueError, OverflowError) as e:
        sys.exit(
            f"Could not read {args.db}: {e}\n"
            "If this is an authorization error, grant your terminal Full Disk"
            " Access (System Settings > Privacy & Security > Full Disk Access)."
        )


if __name__ == "__main__":
    main()
