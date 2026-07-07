"""Tests for scripts/call_log.py against a fixture ZCALLRECORD SQLite DB."""

import importlib.util
import json
import sqlite3
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
            ZCALLTYPE INTEGER)"""
    )
    conn.executemany(
        "INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZDURATION, ZANSWERED,"
        " ZORIGINATED, ZCALLTYPE) VALUES (?,?,?,?,?,?)",
        ROWS,
    )
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
        "direction", "type",
    }


def test_last_command(db, capsys):
    call_log.main(["last", "--contact", "1234", "--db", str(db)])
    out = capsys.readouterr().out
    assert "+12035551234" in out
    assert "2023-03-08" in out  # the newer of the two matching rows
