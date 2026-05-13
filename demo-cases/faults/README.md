# Fault Injection & Recovery Scripts

Bash scripts that drive the 9 deliberate faults (L1-L9) for the China-region
AWS DevOps Agent demo (10 cases C1-C10). See
`docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` for
the case design.

## Fault → Case map

| Fault | What it breaks | Drives case(s) | Inject script |
|-------|---|---|---|
| L1 | bjs1 RDS `bjs-todo-db` Multi-AZ off | C6 (predictive evaluation) | `inject-L1-rds-no-multi-az.sh` |
| L2 | china S3 `china-data-output-*` public + ECS `etl-worker` desired-count=20 | C10 (cost anomaly + ops backlog) | `inject-L2-s3-public-and-ecs-scale.sh` |
| L3 | bjs1 IAM access key on `bjs-demo-rotation-test` "65 days old" (simulated) | C6 (prevention) | `inject-L3-iam-key-old.sh` |
| L4 | Sustained 50 RPS load on `/api/users/search` to surface unindexed query | C2 / C7 / C9 | `inject-L4-unindexed-query-load.sh` |
| L5 | china DDB `etl-state` PROVISIONED 5/5 + ECS scale 5 + 100 SQS msgs | C3 (multi-hop topology RCA) | `inject-L5-etl-oom-ddb-throttle.sh` |
| L6 | bjs1 EKS `todo-api` deployment image set to non-existent tag | C1 (webhook autonomous triage) | `inject-L6-pod-imagepullbackoff.sh` |
| L7 | Trigger Lambda calls `sts:AssumeRole` on broken cross-partition role | C5 (agent error + skill fix) | `inject-L7-cross-partition-trust.sh` |
| L8 | bjs1 ALB target-group health-check-interval = 240s + delete one pod | C4 (blast radius RCA) | `inject-L8-alb-healthcheck-240s.sh` |
| L9 | bjs1 EKS `todo-api` CPU limit patched to `100m` | C9 (multi-source RCA) | `inject-L9-pod-cpu-limit.sh` |

Each `inject-Lx-*.sh` has a paired `recover-Lx-*.sh`.

## Quick start

```bash
# Inject all faults interactively (one prompt per script)
./inject-all.sh

# Inject all without prompts (for the actual demo run)
FAULT_AUTO_YES=1 ./inject-all.sh --yes

# Inject only specific faults
./inject-L6-pod-imagepullbackoff.sh
./inject-L8-alb-healthcheck-240s.sh

# Skip specific faults inside inject-all
./inject-all.sh --skip L4,L7

# Recover everything (always safe; recovers in reverse L9 -> L1)
./recover-all.sh

# Debug mode (set -x inside each script)
./inject-L5-etl-oom-ddb-throttle.sh --debug
```

## Conventions all scripts follow

- First substantive line is `unset AWS_PROFILE AWS_REGION` so leaked env vars
  cannot redirect the script. Every `aws` invocation passes
  `--profile <name> --region <region>` explicitly.
- `set -euo pipefail` on every script.
- Sources `lib/common.sh` for color logging, `validate_profile()`,
  `confirm()`, `parse_debug_flag()`, and an `on_error` trap.
- Logs `log_action "Will <do thing>"` BEFORE every mutating call.
- Recover scripts are idempotent (early-return when already in target state).
- Inject scripts try to be idempotent too (e.g. L1 re-asserts single-AZ even
  if already there; L2/L5 short-circuit if desired-count matches target).

## Environment knobs

Defaults are in `lib/common.sh`. Override by exporting before running:

| Env var | Purpose | Default |
|---|---|---|
| `FAULT_BJS1_PROFILE` | AWS profile for Beijing account | `ychchen-bjs1` |
| `FAULT_BJS1_REGION` | Beijing region | `cn-north-1` |
| `FAULT_CHINA_PROFILE` | Profile for Ningxia account | `ychchen-china` |
| `FAULT_CHINA_REGION` | Ningxia region | `cn-northwest-1` |
| `FAULT_BJS1_RDS_ID` | RDS instance id | `bjs-todo-db` |
| `FAULT_BJS1_EKS_CTX` | kubectl context for bjs1 EKS | `bjs1` |
| `FAULT_BJS1_NS` | k8s namespace | `bjs-web` |
| `FAULT_BJS1_DEPLOY` | k8s deployment | `todo-api` |
| `FAULT_BJS1_GOOD_TAG` | known-good image tag (used by recover-L6) | `v1.2.3` |
| `FAULT_BJS1_BAD_TAG` | broken image tag (used by inject-L6) | `v1.2.4-DOES-NOT-EXIST` |
| `FAULT_BJS1_ALB_NAME` | ALB name to look up TG on | `bjs-web-alb` |
| `BJS_ALB_TG_ARN` | skip ALB discovery, supply TG ARN directly | (auto-discovered) |
| `BJS_WEB_URL` | base URL for L4 load gen | `https://bjs-web.yingchu.cloud` |
| `L4_DURATION` / `L4_RPS` | L4 load duration / RPS | `5m` / `50` |
| `FAULT_AUTO_YES=1` | auto-confirm all `confirm()` prompts | (off) |

## Idempotency notes

- **L1**: re-asserts single-AZ; recover sets multi-AZ on. Safe to re-run.
- **L2**: delete-PAB and put-policy are idempotent; ECS scale only updates
  if desired-count differs.
- **L3**: reuses existing user/key if already created. Recover deletes user
  + all keys + metadata file. Safe to re-run.
- **L4**: pidfile-tracked. Inject errors out if a previous loadgen is alive.
  Recover removes a stale pidfile silently.
- **L5**: every step compares current state before mutating.
- **L6**: writes the previous image to `L6-previous-image.txt` so recover
  can default to it if no `--good-tag` is passed.
- **L7**: probe Lambda is upserted (create-or-update). Recover deletes
  Lambda + execution role; the demo IAM role itself stays.
- **L8**: TG ARN is cached in `L8-target-group-arn.txt`. Recover reads it
  back; falls back to rediscovery if missing.
- **L9**: only patches if current limit differs from target.

## L3 backdating limitation (important for the demo)

AWS does not allow setting `CreateDate` on access keys. The inject script
creates the user + key NOW and writes a sidecar
`L3-simulated-metadata.json` containing a synthetic
`simulated_create_date = now - 65 days`. Two ways to use it:

1. **Real ageing** — run inject-L3 65+ days before the demo and let the
   key age naturally. (Recommended if you have time.)
2. **Skill-side simulation** — tell the C6 prevention skill prompt to read
   `L3-simulated-metadata.json` and treat `simulated_create_date` as the
   canonical timestamp. The skill writes its `90 - age` math against
   that field, not against IAM's actual CreateDate.

The metadata file lives in `demo-cases/faults/L3-simulated-metadata.json`.

## L7 demo trigger design

The bug — `arn:aws:iam::*:role/...` instead of `arn:aws-cn:iam::*:role/...`
in the trust policy — is **baked into terraform** (the role
`bjs-cross-partition-test-role` is the demo artifact and stays alive).

This script is the *trigger*: it deploys a small probe Lambda that calls
`sts:AssumeRole` against the broken role's `arn:aws-cn:` ARN. The call
fails with `AccessDenied` because the trust policy still references
`arn:aws:`. CloudTrail records the failure, giving the agent a real
investigation thread to pull on.

The recover script removes the probe Lambda + its execution role only —
the broken IAM role stays put. To completely tear down the broken role,
use `terraform destroy` in `infra/`.

## Common pitfalls

- **Profile not authenticated** — `validate_profile()` will fail clearly.
  Run `aws sso login --profile <profile>` (or your IAM-credential refresh
  flow) and retry.
- **kubectl context missing** — L6/L8/L9 require `kubectl config get-contexts`
  to include the `bjs1` context. Configure with:
  ```
  aws eks --profile ychchen-bjs1 --region cn-north-1 update-kubeconfig \
      --name bjs-web --alias bjs1
  ```
- **L4 needs a load tool** — script picks `hey` -> `ab` -> python+aiohttp
  in that order. Install `hey` if you want clean throughput numbers:
  `brew install hey`.
- **L5 DDB billing-mode change** — switching to PROVISIONED can take 30s
  to settle; subsequent describe-table will lag.
- **L7 IAM eventual consistency** — first run sleeps 10s after creating
  the execution role. Re-runs reuse it and skip the sleep.
- **Don't run two `inject-all` in parallel** — the L3 user-create / L4
  pidfile / L7 Lambda upsert all assume serial execution.

## Generated artifacts

After running inject scripts, you may see these files in this directory:

| File | Source | Purpose |
|---|---|---|
| `L3-simulated-metadata.json` | inject-L3 | Backdate-simulation metadata for the C6 prevention skill |
| `L4-load.pid` | inject-L4 | PID of background load generator |
| `L4-load.out` | inject-L4 | Stdout/stderr of load generator |
| `.L4-load.py` | inject-L4 | Generated python aiohttp loadgen (only if hey/ab unavailable) |
| `L6-previous-image.txt` | inject-L6 | Pre-injection deployment image for safe rollback |
| `L8-target-group-arn.txt` | inject-L8 | Cached ALB TG ARN |

All cleaned up by their respective recover scripts.
