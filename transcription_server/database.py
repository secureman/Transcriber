import asyncio
import json
from datetime import datetime
from contextlib import asynccontextmanager

import aiosqlite

from config import settings

DB_PATH = "transcriptions.db"

# Module-level lock serializes all writes (aiosqlite is single-connection;
# this makes claim/upsert/status atomic).
_lock = asyncio.Lock()

_SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id TEXT PRIMARY KEY,
    title TEXT,
    author TEXT,
    total_chapters INTEGER,
    abs_item_json TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transcription_jobs (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    chapter_index INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    progress REAL NOT NULL DEFAULT 0,
    vtt_path TEXT,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(book_id, chapter_index)
);
"""


async def _table_columns(db: aiosqlite.Connection, table: str) -> set[str]:
    async with db.execute(f"PRAGMA table_info({table})") as cur:
        rows = await cur.fetchall()
    return {r[1] for r in rows}


async def init_db() -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript(_SCHEMA)
        # Migration for databases created before the progress column existed.
        cols = await _table_columns(db, "transcription_jobs")
        if "progress" not in cols:
            await db.execute(
                "ALTER TABLE transcription_jobs "
                "ADD COLUMN progress REAL NOT NULL DEFAULT 0"
            )
        await db.commit()


@asynccontextmanager
async def _connect():
    db = await aiosqlite.connect(DB_PATH)
    try:
        yield db
        await db.commit()
    finally:
        await db.close()


async def reset_stuck_processing() -> None:
    """Rows left in 'processing' from a previous crash are failed over to
    'pending' so the worker pool picks them up again on next boot."""
    async with _lock:
        async with _connect() as db:
            await db.execute(
                "UPDATE transcription_jobs SET status = 'pending', "
                "updated_at = CURRENT_TIMESTAMP WHERE status = 'processing'"
            )


# ── Books ──────────────────────────────────────────────────────────────


async def upsert_book(item_id: str, title: str, author: str,
                      total_chapters: int, abs_item_json: dict) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """
            INSERT INTO books (id, title, author, total_chapters, abs_item_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title,
                author=excluded.author,
                total_chapters=excluded.total_chapters,
                abs_item_json=excluded.abs_item_json
            """,
            (item_id, title, author, total_chapters,
             json.dumps(abs_item_json)),
        )
        await db.commit()


async def get_book(item_id: str) -> dict | None:
    """Returns the cached ABS item JSON, or None if not cached."""
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT abs_item_json FROM books WHERE id = ?", (item_id,)
        ) as cur:
            row = await cur.fetchone()
    if row is None:
        return None
    return json.loads(row["abs_item_json"])


# ── Jobs ───────────────────────────────────────────────────────────────


async def upsert_job(book_id: str, chapter_index: int) -> str | None:
    """Inserts a pending job. Returns None if a done job already exists."""
    async with _lock:
        async with aiosqlite.connect(DB_PATH) as db:
            # Skip chapters already done.
            async with db.execute(
                "SELECT status FROM transcription_jobs "
                "WHERE book_id = ? AND chapter_index = ?",
                (book_id, chapter_index),
            ) as cur:
                row = await cur.fetchone()
            if row is not None and row[0] == "done":
                return None

            job_id = f"{book_id}-{chapter_index}"
            await db.execute(
                """
                INSERT INTO transcription_jobs
                    (id, book_id, chapter_index, status)
                VALUES (?, ?, ?, 'pending')
                ON CONFLICT(book_id, chapter_index) DO UPDATE SET
                    status='pending',
                    error_message=NULL,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (job_id, book_id, chapter_index),
            )
            await db.commit()
        return job_id


async def set_job_status(job_id: str, status: str,
                         vtt_path: str | None = None,
                         error_message: str | None = None,
                         progress: float | None = None) -> None:
    async with _lock:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.execute(
                """
                UPDATE transcription_jobs
                SET status = ?,
                    vtt_path = COALESCE(?, vtt_path),
                    error_message = ?,
                    progress = COALESCE(?, progress),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                (status, vtt_path, error_message, progress, job_id),
            )
            await db.commit()


async def set_job_progress(job_id: str, progress: float) -> None:
    async with _lock:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.execute(
                "UPDATE transcription_jobs SET progress = ?, "
                "updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                (progress, job_id),
            )
            await db.commit()


async def claim_job() -> str | None:
    """Atomically pops the oldest pending job and marks it processing.
    Returns the job_id or None if no pending jobs."""
    async with _lock:
        async with aiosqlite.connect(DB_PATH) as db:
            async with db.execute(
                "SELECT id FROM transcription_jobs "
                "WHERE status = 'pending' ORDER BY created_at LIMIT 1"
            ) as cur:
                row = await cur.fetchone()
            if row is None:
                return None
            job_id = row[0]
            await db.execute(
                "UPDATE transcription_jobs SET status = 'processing', "
                "updated_at = CURRENT_TIMESTAMP WHERE id = ?", (job_id,))
            await db.commit()
    return job_id


async def get_job(job_id: str) -> dict | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM transcription_jobs WHERE id = ?", (job_id,)
        ) as cur:
            row = await cur.fetchone()
    return dict(row) if row else None


async def get_jobs_for_book(book_id: str) -> list[dict]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM transcription_jobs "
            "WHERE book_id = ? ORDER BY chapter_index",
            (book_id,),
        ) as cur:
            rows = await cur.fetchall()
    return [dict(r) for r in rows]
