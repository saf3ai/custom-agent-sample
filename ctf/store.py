"""
Event state: teams, attempts, solves and the event clock.

SQLite in one file (CTF_DATA_DIR/ctf.db), so every uvicorn worker shares the same
state and a restart keeps the scores. Mount CTF_DATA_DIR as a volume to keep it
across container rebuilds.
"""
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from typing import Optional

DATA_DIR = os.getenv("CTF_DATA_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
DB_PATH = os.path.join(DATA_DIR, "ctf.db")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS teams (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
    code TEXT NOT NULL UNIQUE,
    created_at REAL NOT NULL,
    messages INTEGER NOT NULL DEFAULT 0,
    last_message_at REAL NOT NULL DEFAULT 0,
    last_flag_at REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS attempts (
    id INTEGER PRIMARY KEY,
    team_id INTEGER NOT NULL,
    level INTEGER NOT NULL,
    at REAL NOT NULL,
    outcome TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '',
    prompt TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS solves (
    team_id INTEGER NOT NULL,
    level INTEGER NOT NULL,
    points INTEGER NOT NULL,
    at REAL NOT NULL,
    PRIMARY KEY (team_id, level)
);
"""


@contextmanager
def _db(write: bool = False):
    conn = sqlite3.connect(DB_PATH, timeout=15, isolation_level=None)
    conn.row_factory = sqlite3.Row
    try:
        if write:
            conn.execute("BEGIN IMMEDIATE")  # one writer at a time, across workers
        yield conn
        if write:
            conn.execute("COMMIT")
    except BaseException:
        if write and conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def init() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)
    for attempt in range(5):  # workers start together and may collide on the first write
        try:
            with _db() as conn:
                conn.execute("PRAGMA journal_mode=WAL")
                conn.executescript(_SCHEMA)
            return
        except sqlite3.OperationalError:
            if attempt == 4:
                raise
            time.sleep(0.5)


# ---------------------------------------------------------------- meta + clock

def _get(conn, key: str) -> Optional[str]:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def _set(conn, key: str, value: str) -> None:
    conn.execute("INSERT INTO meta (key, value) VALUES (?, ?) "
                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))


def flag_seed() -> str:
    """CTF_FLAG_SEED if set; otherwise a random seed created once and kept in the database."""
    seed = (os.getenv("CTF_FLAG_SEED") or "").strip()
    if seed:
        return seed
    with _db(write=True) as conn:
        conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('flag_seed', ?)",
                     (secrets.token_hex(16),))
        return _get(conn, "flag_seed")


def event() -> dict:
    """The event clock: status is waiting | running | ended."""
    with _db() as conn:
        started, ends = _get(conn, "started_at"), _get(conn, "ends_at")
        event_id = _get(conn, "event_id") or "0"
    now = time.time()
    if not started:
        return {"status": "waiting", "seconds_left": 0, "event_id": event_id}
    left = float(ends) - now
    return {"status": "running" if left > 0 else "ended", "seconds_left": max(0, int(left)),
            "started_at": float(started), "ends_at": float(ends), "event_id": event_id}


def start(minutes: float) -> dict:
    now = time.time()
    with _db(write=True) as conn:
        _set(conn, "started_at", repr(now))
        _set(conn, "ends_at", repr(now + minutes * 60))
        if not _get(conn, "event_id"):
            _set(conn, "event_id", secrets.token_hex(3))
    return event()


def stop() -> dict:
    with _db(write=True) as conn:
        if _get(conn, "started_at"):
            _set(conn, "ends_at", repr(time.time()))
    return event()


def reset() -> dict:
    """Remove every team, attempt and solve and put the clock back to 'waiting'."""
    with _db(write=True) as conn:
        for table in ("teams", "attempts", "solves"):
            conn.execute(f"DELETE FROM {table}")
        conn.execute("DELETE FROM meta WHERE key IN ('started_at', 'ends_at')")
        _set(conn, "event_id", secrets.token_hex(3))
    return event()


# ---------------------------------------------------------------- teams

def join(name: str) -> Optional[dict]:
    """Create a team -> {id, name, code}; None when the name is taken."""
    code = secrets.token_urlsafe(9)
    try:
        with _db(write=True) as conn:
            cur = conn.execute("INSERT INTO teams (name, code, created_at) VALUES (?, ?, ?)",
                               (name, code, time.time()))
            return {"id": cur.lastrowid, "name": name, "code": code}
    except sqlite3.IntegrityError:
        return None


def team_by_code(code: str) -> Optional[dict]:
    if not code:
        return None
    with _db() as conn:
        row = conn.execute("SELECT id, name, code, messages FROM teams WHERE code = ?", (code,)).fetchone()
    return dict(row) if row else None


def claim_message(team_id: int, min_gap: float, max_messages: int) -> Optional[dict]:
    """Take one message slot for the team. None = go ahead; otherwise why not."""
    now = time.time()
    with _db(write=True) as conn:
        row = conn.execute("SELECT messages, last_message_at FROM teams WHERE id = ?", (team_id,)).fetchone()
        if row["messages"] >= max_messages:
            return {"error": "message_limit", "limit": max_messages}
        wait = min_gap - (now - row["last_message_at"])
        if wait > 0:
            return {"error": "slow_down", "retry_after": round(wait, 1)}
        conn.execute("UPDATE teams SET messages = messages + 1, last_message_at = ? WHERE id = ?",
                     (now, team_id))
    return None


def claim_flag(team_id: int, min_gap: float) -> Optional[dict]:
    now = time.time()
    with _db(write=True) as conn:
        row = conn.execute("SELECT last_flag_at FROM teams WHERE id = ?", (team_id,)).fetchone()
        wait = min_gap - (now - row["last_flag_at"])
        if wait > 0:
            return {"error": "slow_down", "retry_after": round(wait, 1)}
        conn.execute("UPDATE teams SET last_flag_at = ? WHERE id = ?", (now, team_id))
    return None


# ---------------------------------------------------------------- attempts + solves

def record_attempt(team_id: int, level: int, outcome: str, detail: str, prompt: str) -> None:
    """outcome: allowed | flagged | leaked | blocked | error."""
    with _db(write=True) as conn:
        conn.execute("INSERT INTO attempts (team_id, level, at, outcome, detail, prompt) "
                     "VALUES (?, ?, ?, ?, ?, ?)", (team_id, level, time.time(), outcome, detail, prompt))


def solve(team_id: int, level: int, points: int) -> bool:
    """Record a solve. False when the team had already solved this level."""
    with _db(write=True) as conn:
        cur = conn.execute("INSERT OR IGNORE INTO solves (team_id, level, points, at) VALUES (?, ?, ?, ?)",
                           (team_id, level, points, time.time()))
        return cur.rowcount == 1


def solved_levels(team_id: int) -> list:
    with _db() as conn:
        rows = conn.execute("SELECT level FROM solves WHERE team_id = ? ORDER BY level", (team_id,)).fetchall()
    return [row["level"] for row in rows]


def scoreboard() -> list:
    """Teams by points; ties go to the team that reached its score first."""
    with _db() as conn:
        rows = conn.execute(
            "SELECT t.name, COALESCE(SUM(s.points), 0) AS points, COUNT(s.level) AS solved, "
            "       COALESCE(MAX(s.at), t.created_at) AS last_at "
            "FROM teams t LEFT JOIN solves s ON s.team_id = t.id "
            "GROUP BY t.id ORDER BY points DESC, solved DESC, last_at ASC, t.name ASC").fetchall()
    return [{"rank": n, "team": row["name"], "points": row["points"], "solved": row["solved"]}
            for n, row in enumerate(rows, 1)]


def report() -> dict:
    """Numbers for the debrief: outcomes per level, per team, and the prompts that leaked a flag."""
    with _db() as conn:
        by_level = conn.execute(
            "SELECT level, outcome, COUNT(*) AS n FROM attempts GROUP BY level, outcome").fetchall()
        by_team = conn.execute(
            "SELECT t.name, a.level, COUNT(*) AS attempts, "
            "       SUM(a.outcome = 'blocked') AS blocked, SUM(a.outcome = 'flagged') AS flagged "
            "FROM attempts a JOIN teams t ON t.id = a.team_id GROUP BY t.id, a.level").fetchall()
        solves = conn.execute(
            "SELECT t.name, s.level, s.at FROM solves s JOIN teams t ON t.id = s.team_id "
            "ORDER BY s.at").fetchall()
        leaked = conn.execute(
            "SELECT t.name, a.level, a.at, a.prompt FROM attempts a JOIN teams t ON t.id = a.team_id "
            "WHERE a.outcome = 'leaked' ORDER BY a.at").fetchall()
        teams = conn.execute("SELECT COUNT(*) AS n FROM teams").fetchone()["n"]
    levels: dict = {}
    for row in by_level:
        levels.setdefault(row["level"], {})[row["outcome"]] = row["n"]
    for row in solves:
        levels.setdefault(row["level"], {})["solves"] = levels.get(row["level"], {}).get("solves", 0) + 1
    return {
        "teams": teams,
        "levels": levels,
        "by_team": [dict(row) for row in by_team],
        "solves": [dict(row) for row in solves],
        "winning_prompts": [dict(row) for row in leaked],
    }
