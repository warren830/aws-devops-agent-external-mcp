"""FastAPI entrypoint for bjs-todo-api.

Endpoints:
  GET  /healthz                       — liveness, no DB
  GET  /readyz                        — readiness, requires DB SELECT 1
  GET  /api/todos                     — list todos
  POST /api/todos                     — create todo
  GET  /api/users/search?email=...    — *** DELIBERATELY UNINDEXED ***
                                        Drives demo cases C2 / C9.
  POST /api/users                     — create user (used by seed.py)
"""

from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI, HTTPException, Query, Response, status

from . import __version__
from .db import (
    bootstrap_schema,
    close_pool,
    get_pool,
    healthcheck,
    init_pool,
)
from .logging_config import configure_logging
from .models import (
    HealthResponse,
    TodoCreate,
    TodoOut,
    UserCreate,
    UserOut,
)

configure_logging(os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("bjs-todo-api")

# `db/migrations/` lives at the repo root, two parents up from this file
# inside the container (/app/app/main.py → /app/db/migrations).
MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "db" / "migrations"


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    logger.info(
        "startup",
        extra={"event": "app.startup", "version": __version__},
    )
    await init_pool()
    await bootstrap_schema(MIGRATIONS_DIR)
    try:
        yield
    finally:
        logger.info("shutdown", extra={"event": "app.shutdown"})
        await close_pool()


app = FastAPI(
    title="bjs-todo-api",
    version=__version__,
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/healthz", response_model=HealthResponse, tags=["health"])
async def healthz() -> HealthResponse:
    """Liveness probe — no external dependencies."""
    return HealthResponse(status="ok")


@app.get("/readyz", tags=["health"])
async def readyz(response: Response) -> HealthResponse:
    """Readiness probe — verifies DB connectivity."""
    ok = await healthcheck()
    if not ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return HealthResponse(status="unavailable", detail="db unreachable")
    return HealthResponse(status="ok")


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@app.post(
    "/api/users",
    response_model=UserOut,
    status_code=status.HTTP_201_CREATED,
    tags=["users"],
)
async def create_user(payload: UserCreate) -> UserOut:
    pool = get_pool()
    row = await pool.fetchrow(
        """
        INSERT INTO users (email, name)
        VALUES ($1, $2)
        RETURNING id, email, name, created_at
        """,
        payload.email,
        payload.name,
    )
    assert row is not None
    return UserOut(**dict(row))


@app.get("/api/users/search", response_model=list[UserOut], tags=["users"])
async def search_users(
    email: str = Query(..., description="Exact email match"),
) -> list[UserOut]:
    """Look up users by email.

    *** DELIBERATE PERFORMANCE BUG (demo cases C2 / C9) ***
    `users.email` has NO index — once seed.py loads ~10k rows this becomes
    a sequential scan and p99 latency blows up. Do NOT add a `CREATE INDEX`
    here; the fix lives in `db/migrations/0002_add_users_email_index.sql`
    and will be applied by Kiro / Claude Code as part of the C7 demo.
    """
    pool = get_pool()
    started = time.perf_counter()
    rows = await pool.fetch(
        "SELECT id, email, name, created_at FROM users WHERE email = $1",
        email,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    logger.info(
        "user search",
        extra={
            "event": "users.search",
            "email": email,
            "matches": len(rows),
            "duration_ms": round(elapsed_ms, 2),
        },
    )
    return [UserOut(**dict(r)) for r in rows]


# ---------------------------------------------------------------------------
# Todos
# ---------------------------------------------------------------------------

@app.get("/api/todos", response_model=list[TodoOut], tags=["todos"])
async def list_todos() -> list[TodoOut]:
    pool = get_pool()
    rows = await pool.fetch(
        """
        SELECT id, user_id, title, completed, created_at
        FROM todos
        ORDER BY id DESC
        LIMIT 500
        """
    )
    return [TodoOut(**dict(r)) for r in rows]


@app.post(
    "/api/todos",
    response_model=TodoOut,
    status_code=status.HTTP_201_CREATED,
    tags=["todos"],
)
async def create_todo(payload: TodoCreate) -> TodoOut:
    pool = get_pool()
    row = await pool.fetchrow(
        """
        INSERT INTO todos (user_id, title, completed)
        VALUES ($1, $2, $3)
        RETURNING id, user_id, title, completed, created_at
        """,
        payload.user_id,
        payload.title,
        payload.completed,
    )
    if row is None:
        raise HTTPException(status_code=500, detail="failed to insert todo")
    return TodoOut(**dict(row))
