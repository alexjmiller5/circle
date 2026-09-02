# Call log CLI (`scripts/call_log.py`)

Standalone stdlib-only Python CLI (PEP 723) that reads macOS call history —
phone + FaceTime — from `~/Library/Application Support/CallHistoryDB/CallHistory.storedata`
(the Core Data SQLite store, path also in `callhistorypath.txt`). It always
copies the store (+ `-shm`/`-wal` sidecars) to a temp dir and opens the copy
read-only, never the live store.

## Usage

```sh
uv run scripts/call_log.py recent [--limit N] [--since YYYY-MM-DD] [--contact SUBSTRING] [--json]
uv run scripts/call_log.py last --contact SUBSTRING
# or: just calls recent --limit 10
```

`--json` emits machine-readable output for future Circle sync. Contact
matching is a substring match on the raw handle (`ZADDRESS`).

## Data notes

- `ZDATE` is seconds since 2001-01-01 UTC (Apple epoch, +978307200 for unix).
- `ZCALLTYPE` values observed in the real DB: 1 = phone (com.apple.Telephony),
  8 = FaceTime video, 16 = FaceTime audio. No WhatsApp rows were present as of
  2026-07-07; unknown types print as `unknown(N)`.

## Full Disk Access (manual step — cannot be codified)

The `CallHistoryDB` directory is TCC-protected. If the CLI exits with an
authorization/permission error, grant your terminal app Full Disk Access:
System Settings > Privacy & Security > Full Disk Access, then restart the
terminal.

## Follow-ups

- Resolve handles to Contacts names (needs Contacts DB / CNContactStore).

## Tests

```sh
just test   # uv run --with pytest pytest tests/
```

Tests run against a fixture DB built in `tmp_path`; no real data or FDA needed.
