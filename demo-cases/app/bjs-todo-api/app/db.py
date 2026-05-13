"""Asyncpg connection pool + schema bootstrap.

Migrations are intentionally NOT auto-applied beyond `0001_initial.sql` —
`0002_add_users_email_index.sql` exists in `db/migrations/` but is
deliberately skipped at startup so the C2 / C9 demo bug (unindexed query
on `users.email`) reproduces in production.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Optional

import asyncpg

logger = logging.getLogger(__name__)

# Only the initial schema is auto-applied. The "fix" migration
# (0002_add_users_email_index.sql) is intentionally skipped — it is what
# Kiro / Claude Code will commit during the C7 closed-loop demo.
BOOTSTRAP_MIGRATIONS = ["0001_initial.sql"]

_pool: Optional[asyncpg.Pool] = None


def get_database_url() -> str:
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL environment variable is required")
    return url


async def init_pool() -> asyncpg.Pool:
    """Create the global connection pool (idempotent)."""
    global _pool
    if _pool is None:
        dsn = get_database_url()
        logger.info("creating asyncpg pool", extra={"event": "db.pool.init"})
        _pool = await asyncpg.create_pool(
            dsn=dsn,
            min_size=1,
            max_size=10,
            command_timeout=30,
        )
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("DB pool is not initialized")
    return _pool


async def bootstrap_schema(migrations_dir: Path) -> None:
    """Apply only the bootstrap migrations.

    NOTE: We deliberately do NOT scan and apply every `.sql` in the directory.
    `0002_add_users_email_index.sql` MUST stay un-applied so the C2 / C9 demo
    surfaces a real, slow, unindexed query.
    """
    pool = await init_pool()
    async with pool.acquire() as conn:
        for name in BOOTSTRAP_MIGRATIONS:
            path = migrations_dir / name
            if not path.exists():
                logger.warning(
                    "migration not found, skipping",
                    extra={"event": "db.migration.missing", "file": str(path)},
                )
                continue
            sql = path.read_text(encoding="utf-8")
            logger.info(
                "applying migration",
                extra={"event": "db.migration.apply", "file": name},
            )
            await conn.execute(sql)


async def healthcheck() -> bool:
    """Lightweight readiness probe — issues `SELECT 1`."""
    if _pool is None:
        return False
    try:
        async with _pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "db healthcheck failed",
            extra={"event": "db.health.fail", "error": str(exc)},
        )
        return False
