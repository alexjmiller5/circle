# Call history reader

Read-only macOS phone/FaceTime call metadata from the local CallHistory SQLite
store. The reader uses a single read-only transaction, including committed WAL
records. It never writes the source or copies private records into the repo.

```sh
circle-calls recent --limit 25 --json
circle-calls recent --since 2026-01-01 --contact '<handle>' --json
circle-calls last --contact '<handle>'
circle-calls coverage
```

Build the installable CLI with `nix build .#circle-calls`, or add
`inputs.circle.packages.${pkgs.system}.circle-calls` to a Home Manager package
list. It runs from the Nix store and needs no working checkout. For development,
use `just calls` or `uv run scripts/call_log.py`. Override the source with `--db`.

The default source is
`~/Library/Application Support/CallHistoryDB/CallHistory.storedata`.
Full Disk Access is native user state: if access is denied, grant the invoking
terminal or installed host in System Settings > Privacy & Security > Full Disk
Access. A replacement machine needs its own permission and source-app sign-in.
The reader cannot enable iCloud call sync or recover unavailable history.

JSON preserves source timestamp precision, UTC date, raw handle, duration,
nullable answered status, direction (including unknown), call type and service
provider. Known call-type codes identify phone and FaceTime categories; the
provider remains independent evidence. Do not infer WhatsApp coverage from a
phone type or infer a direct call/full participant list from one address.

`source_id` uses the native event ID when available, otherwise the local row
key; `identity_kind` explicitly distinguishes them. `source_namespace` is an
opaque hash of the source store UUID. Deduplicate within that namespace, never
by contact/time alone. A store-local row ID is not a cross-device identity.
Unknown flags and durations remain unknown. `coverage` reports observed bounds
and counts only: retention, iCloud synchronization and complete participants
are unproven, so missing calls never mean no contact happened.

The output contains private handles and stays outside git. Canonical person
resolution, metadata publication and cross-device reconciliation belong to the
contact-history importer. This utility neither imports records nor sends calls.

Tests use synthetic SQLite stores, including a live WAL fixture. `just test`
runs these and the native model tests without accessing personal history.
