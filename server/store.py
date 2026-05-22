"""
SQLite 存储：会话 / 图 / 状态 / 日志。
"""
from __future__ import annotations

import json
import sqlite3
import time
import threading
from pathlib import Path
from typing import Any


_DB_PATH = Path(__file__).parent / "data.db"
_lock = threading.Lock()


def _conn() -> sqlite3.Connection:
    c = sqlite3.connect(_DB_PATH, check_same_thread=False)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    # WAL：读写并发，写入只 fsync WAL 文件而非主库；synchronous=NORMAL
    # 让 fsync 不在每次 COMMIT 都做（在 checkpoint 时做），写延迟下降一个量级
    c.execute("PRAGMA journal_mode = WAL")
    c.execute("PRAGMA synchronous = NORMAL")
    return c


def init_db() -> None:
    with _lock, _conn() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                hostname TEXT,
                workdir TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS graphs (
                session_id TEXT PRIMARY KEY,
                nodes_json TEXT NOT NULL,
                edges_json TEXT NOT NULL,
                dot_raw TEXT,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS resource_states (
                session_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                status TEXT NOT NULL,
                action TEXT,
                message TEXT,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(session_id, node_id),
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                ts INTEGER NOT NULL,
                stream TEXT NOT NULL,
                line TEXT NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_logs_session ON logs(session_id, id);
            """
        )


# ---- sessions ----

def upsert_session(sid: str, name: str, hostname: str, workdir: str) -> None:
    now = int(time.time())
    with _lock, _conn() as c:
        c.execute(
            """
            INSERT INTO sessions(id, name, hostname, workdir, created_at, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              hostname=excluded.hostname,
              workdir=excluded.workdir,
              updated_at=excluded.updated_at
            """,
            (sid, name, hostname, workdir, now, now),
        )


def list_sessions() -> list[dict[str, Any]]:
    with _lock, _conn() as c:
        rows = c.execute(
            "SELECT * FROM sessions ORDER BY updated_at DESC"
        ).fetchall()
        return [dict(r) for r in rows]


def get_session(sid: str) -> dict[str, Any] | None:
    with _lock, _conn() as c:
        r = c.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return dict(r) if r else None


def delete_session(sid: str) -> None:
    with _lock, _conn() as c:
        c.execute("DELETE FROM sessions WHERE id=?", (sid,))


# ---- graph ----

def save_graph(sid: str, nodes: list, edges: list, dot_raw: str) -> None:
    now = int(time.time())
    with _lock, _conn() as c:
        c.execute(
            """
            INSERT INTO graphs(session_id, nodes_json, edges_json, dot_raw, updated_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
              nodes_json=excluded.nodes_json,
              edges_json=excluded.edges_json,
              dot_raw=excluded.dot_raw,
              updated_at=excluded.updated_at
            """,
            (sid, json.dumps(nodes), json.dumps(edges), dot_raw, now),
        )
        c.execute("UPDATE sessions SET updated_at=? WHERE id=?", (now, sid))


def get_graph(sid: str) -> dict[str, Any] | None:
    with _lock, _conn() as c:
        r = c.execute(
            "SELECT nodes_json, edges_json, updated_at FROM graphs WHERE session_id=?",
            (sid,),
        ).fetchone()
        if not r:
            return None
        return {
            "nodes": json.loads(r["nodes_json"]),
            "edges": json.loads(r["edges_json"]),
            "updated_at": r["updated_at"],
        }


# ---- states ----

def update_state(sid: str, node_id: str, status: str, action: str | None, message: str | None) -> dict:
    now = int(time.time())
    with _lock, _conn() as c:
        c.execute(
            """
            INSERT INTO resource_states(session_id, node_id, status, action, message, updated_at)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(session_id, node_id) DO UPDATE SET
              status=excluded.status,
              action=COALESCE(excluded.action, resource_states.action),
              message=excluded.message,
              updated_at=excluded.updated_at
            """,
            (sid, node_id, status, action, message, now),
        )
    return {
        "node_id": node_id,
        "status": status,
        "action": action,
        "message": message,
        "updated_at": now,
    }


def list_states(sid: str) -> list[dict[str, Any]]:
    with _lock, _conn() as c:
        rows = c.execute(
            "SELECT node_id, status, action, message, updated_at FROM resource_states WHERE session_id=?",
            (sid,),
        ).fetchall()
        return [dict(r) for r in rows]


def reset_states(sid: str) -> None:
    with _lock, _conn() as c:
        c.execute("DELETE FROM resource_states WHERE session_id=?", (sid,))


def clear_logs(sid: str) -> None:
    """清空会话的全部日志（重新上传图时调用，开始新一轮）。"""
    with _lock, _conn() as c:
        c.execute("DELETE FROM logs WHERE session_id=?", (sid,))


# ---- logs ----

def append_log(sid: str, stream: str, line: str, ts: int | None = None) -> int:
    ts = ts or int(time.time() * 1000)
    with _lock, _conn() as c:
        cur = c.execute(
            "INSERT INTO logs(session_id, ts, stream, line) VALUES(?,?,?,?)",
            (sid, ts, stream, line),
        )
        return cur.lastrowid


def append_logs_batch(
    sid: str, items: list[tuple[str, str]],
) -> list[tuple[int, int, str, str]]:
    """批量插入日志。一个事务、一次 fsync，比逐条 INSERT 快 N 倍。
    items: list of (stream, line)
    返回: list of (id, ts, stream, line)
    """
    if not items:
        return []
    ts = int(time.time() * 1000)
    rows: list[tuple[int, int, str, str]] = []
    with _lock, _conn() as c:
        for stream, line in items:
            cur = c.execute(
                "INSERT INTO logs(session_id, ts, stream, line) VALUES(?,?,?,?)",
                (sid, ts, stream, line),
            )
            rows.append((cur.lastrowid, ts, stream, line))
    return rows


def list_logs(sid: str, limit: int = 1000, after_id: int = 0) -> list[dict[str, Any]]:
    with _lock, _conn() as c:
        rows = c.execute(
            """
            SELECT id, ts, stream, line FROM logs
            WHERE session_id=? AND id>?
            ORDER BY id ASC LIMIT ?
            """,
            (sid, after_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]
