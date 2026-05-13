"""Seed script — POSTs ~10,000 users to populate the database.

Used by Phase 2 deploy so the unindexed `WHERE email = ?` query in
`GET /api/users/search` becomes measurably slow (the demo bug for C2 / C9).

Usage:
    BASE_URL=http://localhost:8000 python seed.py
    BASE_URL=http://bjs-web.yingchu.cloud TOTAL=10000 python seed.py
"""

from __future__ import annotations

import asyncio
import os
import random
import string
import sys
from typing import Any

import httpx


def _random_email() -> str:
    local = "".join(random.choices(string.ascii_lowercase + string.digits, k=10))
    domain = random.choice(
        ["example.com", "demo.local", "test.io", "yingchu.cloud", "bjs.aws.cn"]
    )
    return f"{local}@{domain}"


def _random_name() -> str:
    first = random.choice(
        ["Wei", "Lei", "Min", "Yan", "Bo", "Hui", "Lin", "Jian", "Xue", "Hao"]
    )
    last = random.choice(
        ["Wang", "Li", "Zhang", "Liu", "Chen", "Yang", "Huang", "Zhao", "Wu"]
    )
    return f"{first} {last}"


async def _post_one(client: httpx.AsyncClient, base: str) -> dict[str, Any] | None:
    payload = {"email": _random_email(), "name": _random_name()}
    try:
        r = await client.post(f"{base}/api/users", json=payload, timeout=10.0)
        if r.status_code == 201:
            return r.json()
        print(f"unexpected {r.status_code}: {r.text[:200]}", file=sys.stderr)
    except httpx.HTTPError as exc:
        print(f"request failed: {exc}", file=sys.stderr)
    return None


async def main() -> int:
    base = os.environ.get("BASE_URL", "http://localhost:8000").rstrip("/")
    total = int(os.environ.get("TOTAL", "10000"))
    concurrency = int(os.environ.get("CONCURRENCY", "32"))

    print(f"seeding {total} users → {base} (concurrency={concurrency})")

    sem = asyncio.Semaphore(concurrency)
    success = 0

    async with httpx.AsyncClient() as client:
        async def _bounded() -> None:
            nonlocal success
            async with sem:
                if await _post_one(client, base) is not None:
                    success += 1

        tasks = [asyncio.create_task(_bounded()) for _ in range(total)]
        for i, task in enumerate(asyncio.as_completed(tasks), start=1):
            await task
            if i % 500 == 0:
                print(f"  progress: {i}/{total} ({success} ok)")

    print(f"done: {success}/{total} users created")
    return 0 if success > 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
