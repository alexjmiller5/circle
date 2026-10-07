"""Tests for scripts/call_log.py against a fixture ZCALLRECORD SQLite DB."""

import importlib.util
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

_spec = importlib.util.spec_from_file_location(
    "call_log", Path(__file__).parent.parent / "scripts" / "call_log.py"
)
call_log = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(call_log)

APPLE = 978307200  # 2001-01-01 UTC as unix ts

# (ZDATE apple-epoch, ZADDRESS, ZDURATION, ZANSWERED, ZORIGINATED, ZCALLTYPE)
ROWS = [
    (700000000, "+12035551234", 120.0, 1, 1, 1),   # outgoing phone, answered
    (700000100, "+12035555678", 0.0, 0, 0, 1),     # incoming phone, missed
    (700000200, "+447700900123", 300.5, 1, 0, 8),  # incoming FaceTime video
    (600000000, "+12035551234", 45.0, 1, 0, 16),   # old FaceTime audio, same contact
]


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "CallHistory.storedata"
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE ZCALLRECORD (
            Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZADDRESS VARCHAR,
            ZDURATION FLOAT, ZANSWERED INTEGER, ZORIGINATED INTEGER,
            ZCALLTYPE INTEGER, ZUNIQUE_ID TEXT, ZSERVICE_PROVIDER TEXT)"""
    )
    conn.executemany(
        "INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZDURATION, ZANSWERED,"
        " ZORIGINATED, ZCALLTYPE) VALUES (?,?,?,?,?,?)",
        ROWS,
    )
    conn.execute("CREATE TABLE Z_METADATA (Z_UUID TEXT)")
    conn.execute("INSERT INTO Z_METADATA VALUES ('fixture-store')")
    conn.commit()
    conn.close()
    return path


def test_ordering_newest_first(db):
    calls = call_log.fetch_calls(db)
    dates = [c["timestamp"] for c in calls]
    assert dates == sorted(dates, reverse=True)
    assert calls[0]["address"] == "+447700900123"


def test_epoch_conversion(db):
    calls = call_log.fetch_calls(db, contact="5678")
    # 700000100 + 978307200 = 1678307300 = 2023-03-08T20:28:20+00:00
    assert calls[0]["timestamp"] == 1678307300
    assert calls[0]["date"].startswith("2023-03-08")


def test_limit(db):
    assert len(call_log.fetch_calls(db, limit=2)) == 2


def test_since_filter(db):
    # cutoff between the old row and the three recent ones
    calls = call_log.fetch_calls(db, since="2023-01-01")
    assert len(calls) == 3
    assert all(c["timestamp"] >= 1672531200 for c in calls)


def test_contact_substring(db):
    calls = call_log.fetch_calls(db, contact="+1203555123")
    assert len(calls) == 2
    assert {c["address"] for c in calls} == {"+12035551234"}


def test_direction_and_calltype(db):
    calls = call_log.fetch_calls(db)
    by_addr = {c["address"]: c for c in calls if c["address"] != "+12035551234"}
    assert by_addr["+12035555678"]["direction"] == "incoming"
    assert by_addr["+12035555678"]["answered"] is False
    assert by_addr["+447700900123"]["type"] == "facetime-video"
    out = [c for c in calls if c["direction"] == "outgoing"]
    assert len(out) == 1 and out[0]["type"] == "phone"


def test_json_output(db, capsys):
    call_log.main(["recent", "--db", str(db), "--json", "--limit", "1"])
    data = json.loads(capsys.readouterr().out)
    assert isinstance(data, list) and len(data) == 1
    assert set(data[0]) == {
        "date", "timestamp", "address", "duration", "answered",
        "direction", "type", "source_id", "source_namespace",
        "identity_kind", "service_provider",
    }


def test_last_command(db, capsys):
    call_log.main(["last", "--contact", "1234", "--db", str(db)])
    out = capsys.readouterr().out
    assert "+12035551234" in out
    assert "2023-03-08" in out  # the newer of the two matching rows


def test_native_identity_and_fractional_source_time(db):
    with sqlite3.connect(db) as conn:
        conn.execute("UPDATE ZCALLRECORD SET ZUNIQUE_ID='event-1', ZDATE=700000200.25 WHERE Z_PK=3")
    row = call_log.fetch_calls(db, limit=1)[0]
    assert row["source_id"] == "event-1"
    assert row["identity_kind"] == "native"
    assert row["timestamp"] == 1678307400.25


def test_store_local_identity_survives_copy_and_separates_stores(db, tmp_path):
    import shutil
    copied = tmp_path / "other.storedata"
    shutil.copyfile(db, copied)
    first = call_log.fetch_calls(db)[0]
    same = call_log.fetch_calls(copied)[0]
    assert first["source_id"] == same["source_id"] == "3"
    assert first["source_namespace"] == same["source_namespace"]
    assert first["identity_kind"] == "store_local"
    with sqlite3.connect(copied) as conn:
        conn.execute("UPDATE Z_METADATA SET Z_UUID='different-store'")
    other = call_log.fetch_calls(copied)[0]
    assert first["source_namespace"] != other["source_namespace"]


def test_unknown_flags_are_not_missed_incoming_calls(db):
    with sqlite3.connect(db) as conn:
        conn.execute("UPDATE ZCALLRECORD SET ZANSWERED=NULL, ZORIGINATED=NULL, ZDURATION=NULL WHERE Z_PK=3")
    row = call_log.fetch_calls(db, limit=1)[0]
    assert row["answered"] is None
    assert row["direction"] == "unknown"
    assert row["duration"] is None


def test_committed_wal_rows_are_visible_without_modifying_source(db):
    conn = sqlite3.connect(db)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("INSERT INTO ZCALLRECORD (ZDATE,ZUNIQUE_ID) VALUES (800000000,'wal-event')")
    conn.commit()
    before = db.read_bytes()
    try:
        assert call_log.fetch_calls(db, limit=1)[0]["source_id"] == "wal-event"
        assert db.read_bytes() == before
    finally:
        conn.close()


def test_contact_filter_is_literal_not_sql_wildcard(db):
    assert call_log.fetch_calls(db, contact="%") == []
    assert call_log.fetch_calls(db, contact="_") == []


@pytest.mark.parametrize("limit", [0, -1])
def test_invalid_limits_fail_without_dumping_all_records(db, limit):
    result = subprocess.run([sys.executable, str(_spec.origin), "recent", "--db", str(db), "--limit", str(limit), "--json"], capture_output=True, text=True)
    assert result.returncode != 0
    assert result.stdout == ""
    assert "positive" in result.stderr.lower()


def test_missing_identity_namespace_fails_closed(db):
    with sqlite3.connect(db) as conn:
        conn.execute("DELETE FROM Z_METADATA")
    with pytest.raises(ValueError, match="store identity"):
        call_log.fetch_calls(db)


def test_coverage_is_observed_inventory_not_complete_history(db, capsys):
    call_log.main(["coverage", "--db", str(db)])
    output = capsys.readouterr().out
    result = json.loads(output)
    assert result["observed_rows"] == 4
    assert result["history_complete"] is False
    assert result["oldest_timestamp"] == 1578307200
    assert result["newest_timestamp"] == 1678307400
    assert "address" not in output
