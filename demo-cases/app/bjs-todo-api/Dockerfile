# syntax=docker/dockerfile:1.7
# bjs-todo-api — multi-stage build, target linux/amd64.
# Base image is on public ECR so the China-region pull works.

# ---- builder ----------------------------------------------------------------
FROM public.ecr.aws/docker/library/python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Build deps for asyncpg / email-validator wheels (slim is, well, slim).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --prefix=/install -r requirements.txt

# ---- runtime ----------------------------------------------------------------
FROM public.ecr.aws/docker/library/python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PORT=8000 \
    LOG_LEVEL=INFO

WORKDIR /app

# Bring in the resolved site-packages from the builder layer.
COPY --from=builder /install /usr/local

# Drop privileges — image runs as a dedicated non-root user.
RUN useradd --create-home --shell /usr/sbin/nologin --uid 10001 appuser

# App source.
COPY app /app/app
COPY db /app/db
COPY seed.py /app/seed.py

USER appuser

EXPOSE 8000

# Use uvicorn directly; gunicorn isn't needed for a 3-replica deployment.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
