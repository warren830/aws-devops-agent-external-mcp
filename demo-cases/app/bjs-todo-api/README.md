# bjs-todo-api

Tiny FastAPI demo app for the AWS DevOps Agent China-region 10-cases demo.
Lives at `cn-north-1` on the `bjs-web` EKS cluster fronted by an internal
ALB. It is intentionally small and contains a **deliberate performance
bug** that drives demo cases C2 (time-anchored deploy correlation), C7
(agent-ready spec → coding agent closes the loop), and C9 (5-source RCA).

## Repository layout

```
bjs-todo-api/
  app/                       FastAPI source
    main.py                  Endpoints + lifespan
    db.py                    asyncpg pool + bootstrap migration runner
    models.py                Pydantic request/response models
    logging_config.py        OTel-style structured JSON logging
  db/migrations/
    0001_initial.sql         Schema (NO index on users.email — by design)
    0002_add_users_email_index.sql   Fix migration; NOT auto-applied
  k8s/
    namespace.yaml           Namespace bjs-web
    deployment.yaml          3 replicas, GOOD resource limits baseline
    service.yaml             ClusterIP
    ingress.yaml             Internal ALB via AWS LB Controller
    secret-template.yaml     Template for bjs-todo-db-secret (do not commit)
  Dockerfile                 Multi-stage, linux/amd64, public ECR base
  docker-compose.yml         Local dev (postgres + api)
  Makefile                   build / push / deploy / seed / local-run
  seed.py                    Populates ~10k users so the bug is observable
  requirements.txt
```

## Endpoints

| Method | Path                            | Notes                                        |
|--------|---------------------------------|----------------------------------------------|
| GET    | `/healthz`                      | Liveness; no DB. Used by ALB + k8s liveness. |
| GET    | `/readyz`                       | Readiness; `SELECT 1` against the DB.        |
| GET    | `/api/todos`                    | Recent 500 todos.                            |
| POST   | `/api/todos`                    | Create todo `{user_id,title,completed}`.     |
| GET    | `/api/users/search?email=...`   | **The deliberate bug**, see below.           |
| POST   | `/api/users`                    | Create user (used by `seed.py`).             |

## The deliberate bug (C2 / C9)

`GET /api/users/search?email=...` runs `SELECT * FROM users WHERE email = $1`
against a column that **has no index**. Once `seed.py` loads ~10,000 rows
the query becomes a sequential scan and p99 latency on this endpoint
visibly blows up.

- The schema is locked in by `db/migrations/0001_initial.sql` — no index.
- The fix exists at `db/migrations/0002_add_users_email_index.sql` but is
  **not applied by the app at startup**. `app/db.py` only runs migrations
  named in `BOOTSTRAP_MIGRATIONS` (= just `0001_initial.sql`).
- During the C7 demo, the agent-ready spec instructs Kiro / Claude Code to
  add this migration to the registered set and ship a PR. Until then the
  bug stays present in production.

If you "accidentally" fix this in code, the demo will self-heal — please
don't.

## Local development

Prereqs: Docker + Docker Compose.

```bash
make local-run
# In another shell:
curl -s http://localhost:8000/healthz
curl -s -X POST http://localhost:8000/api/users \
    -H 'content-type: application/json' \
    -d '{"email":"a@b.com","name":"Alice"}'
curl -s "http://localhost:8000/api/users/search?email=a@b.com"
TOTAL=10000 BASE_URL=http://localhost:8000 python seed.py
```

To prove the bug locally:

```bash
docker compose exec postgres psql -U todo -d todos \
    -c "EXPLAIN ANALYZE SELECT * FROM users WHERE email='a@b.com';"
# expect: Seq Scan on users, ~10k rows scanned
```

After applying the fix migration manually:

```bash
docker compose exec -T postgres psql -U todo -d todos \
    < db/migrations/0002_add_users_email_index.sql
# now EXPLAIN ANALYZE shows: Index Scan using idx_users_email
```

## Build & deploy

```bash
# Build the linux/amd64 image
make build IMAGE_TAG=v1.2.3

# Push to ECR (cn-north-1)
make push \
    ECR_REPO_URL=034362076319.dkr.ecr.cn-north-1.amazonaws.com.cn/bjs-todo-api \
    AWS_PROFILE=ychchen-bjs1

# Create the DB secret (one-time, real password not committed):
kubectl --context bjs1 -n bjs-web create secret generic bjs-todo-db-secret \
    --from-literal=DATABASE_URL="postgresql://todo:$DB_PASSWORD@bjs-todo-db.cn-north-1.rds.amazonaws.com.cn:5432/todos" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD"

# Deploy (envsubst replaces ${ECR_REPO_URL} in deployment.yaml):
make deploy \
    ECR_REPO_URL=034362076319.dkr.ecr.cn-north-1.amazonaws.com.cn/bjs-todo-api \
    K8S_CONTEXT=bjs1
```

## Seeding production

After the deployment is healthy:

```bash
BASE_URL=http://bjs-web.yingchu.cloud TOTAL=10000 make seed
```

## Demo case crib-sheet

| Case | What this app provides                                                  |
|------|-------------------------------------------------------------------------|
| C1   | Image tag set to `v1.2.4` causes ImagePullBackOff (image doesn't exist).|
| C2   | Slow `users/search` after seed → CW p99 alarm → agent correlates commit.|
| C7   | RCA → agent-ready spec → Kiro adds `0002_add_users_email_index.sql`.    |
| C9   | C2 bug + `cpu: 100m` limit injection → 5-source RCA correlates both.    |

## Operational notes

- Container runs as non-root uid 10001 with read-only root FS.
- Logs are OTel-style single-line JSON to stdout; CloudWatch Logs picks
  them up and the JSON fields are queryable in Logs Insights.
- DB connection pool: `min_size=1`, `max_size=10`, command timeout 30s.
- Bootstrap schema is idempotent (`CREATE TABLE IF NOT EXISTS`).

## Known sharp edges (intentional)

1. `users.email` has no index. Don't fix it here — fix lives in the C7 PR.
2. Deployment baseline cpu limit is 500m (good); C9 patches it to 100m
   (bad). Apply `kubectl rollout restart` to revert after the case.
3. The image pull base is `public.ecr.aws/docker/library/python:3.12-slim`
   which is mirrored into China region by AWS — do not change to docker.io.
