# C7 — Agent-Ready Spec → Coding Agent Loop (Kiro / Claude Code)

> Design reference: `../../docs/superpowers/specs/2026-05-13-china-region-10-wow-cases-design.md` § 2 Case 7

## TL;DR

Take the RCA from **C2** (missing index on `users.email`) and **continue
the loop**: ask the DevOps Agent to produce an **agent-ready spec** —
a structured handoff document — and paste it into a coding agent
(Claude Code or Kiro). The coding agent reads the spec, opens the
`bjs-todo-api` GitHub repo, writes a migration `0042_add_users_email_index.sql`,
registers it in the migration runner, and **opens a PR**. The DevOps
Agent identified the bug; the coding agent ships the fix. End-to-end
agentic SRE in two hops.

## Prereqs

- [ ] **C2 has been completed in this session** (or you have the C2 RCA
      report saved somewhere the agent can reference). The agent must
      have a concrete RCA to build the spec from.
- [ ] Agent Space wired and authenticated; GitHub repo `bjs-todo-api`
      connected for read-AND-write (the coding agent needs push access)
- [ ] Local terminal has either:
  - `claude` CLI installed (for Claude Code), and the user is logged in, **or**
  - `kiro` CLI installed and authenticated
- [ ] Local clone of `bjs-todo-api` repo exists and is on `main`, clean
      working tree
- [ ] CI on `bjs-todo-api` runs migration tests on PR (so we can verify
      the new migration passes before merge)

```bash
# Verify Claude Code is installed and authenticated
claude --version
# expect: a version string (no auth error)

# Verify the local repo is clean
cd ~/code/bjs-todo-api  # adjust to your path
git status
# expect: nothing to commit, working tree clean
git log --oneline -5
# expect: the recent unindexed-query commit visible
```

## Inject

**No new fault injection.** This case continues C2. If C2's L4 load
generator is still running, you can leave it on; if it finished its
default 5-minute window, that's also fine — the RCA is already produced
and we are now in the *fix* phase.

If you want to start fresh, re-run C2's inject:

```bash
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./inject-L4-unindexed-query-load.sh
# then ask the agent the C2 query first to regenerate the RCA
```

## Trigger / Query

This case has **two queries**, executed in sequence on two different
agents.

### Step 1 — In Agent Space (DevOps Agent)

After C2's RCA is in the conversation, type:

```
Generate a mitigation plan for that RCA in 4 phases (Prepare / Pre-Validate / Apply / Post-Validate). Then convert it into an agent-ready spec I can hand to a coding agent.
```

Expected: agent emits a 4-phase mitigation plan, then **a separate
markdown spec** with these sections:
- **Context** — link/reference to the RCA, incident ID
- **Goal** — add an index on `users.email` to fix the unindexed query
- **Required changes** — file paths and what to change
  (e.g. `db/migrations/0042_add_users_email_index.sql` new file with
  `CREATE INDEX idx_users_email ON users(email);`,
  registration in `db/migrate.go` or equivalent)
- **Acceptance criteria** — migration applies cleanly; query plan in
  `EXPLAIN ANALYZE` switches from `Seq Scan` to `Index Scan`
- **Rollback** — the corresponding `DROP INDEX` in a paired down
  migration
- **References** — RCA report URL, commit hash that introduced the bug

Copy the entire spec to your clipboard.

### Step 2 — In a separate terminal, hand off to Claude Code

```bash
cd ~/code/bjs-todo-api
git checkout -b fix/add-users-email-index
claude
```

In the Claude Code session, paste:

```
Here is an agent-ready spec from our DevOps Agent. Implement it:

<paste the spec here>

Open a PR titled "fix(db): add idx_users_email to fix unindexed search query". Reference the incident in the PR description.
```

Claude Code should:
1. Create `db/migrations/0042_add_users_email_index.sql` with the
   `CREATE INDEX` statement.
2. Create the paired `0042_add_users_email_index.down.sql` (or equivalent
   convention) with `DROP INDEX`.
3. Update the migration registry file (e.g. `db/migrate.go`,
   `migrations/__init__.py`, etc., depending on the actual repo).
4. Commit with a descriptive message.
5. Push the branch and open a PR via `gh pr create` (or equivalent),
   referencing the incident ID and RCA report URL from the spec.

## Expected Agent Behavior

**DevOps Agent**:
- Emits a 4-phase mitigation plan (Prepare / Pre-Validate / Apply /
  Post-Validate).
- Emits an agent-ready spec that is **self-contained** — a coding agent
  reading only the spec (no access to Agent Space) can do the work.
- Spec uses concrete filenames and code references, not hand-wavy
  "add an index somewhere" prose.

**Claude Code**:
- Reads the spec, plans the change, asks at most one clarifying question
  (or none).
- Writes the migration file with the exact SQL.
- Updates the migration runner registration.
- Creates a feature branch.
- Pushes and opens the PR with the incident references inline.
- Total handoff time ≤ 5 minutes from "paste spec" to "PR opened".

## Acceptance Criteria

- [ ] Agent-ready spec is **self-contained** — pass the spec text alone
      (no other context) to a fresh coding agent and the agent can act
- [ ] Spec contains: context, goal, required changes (file:line),
      acceptance criteria, rollback, references
- [ ] Claude Code generates the migration file with the **exact** SQL
      `CREATE INDEX idx_users_email ON users(email);`
- [ ] PR is opened to `bjs-todo-api` repo
- [ ] PR description references the incident ID **and** the RCA report
      URL (or commit hash that introduced the bug)
- [ ] CI on the PR passes (or, if CI is not wired, the migration runs
      locally without error)

## Screenshots to capture

Save under `blog/screenshots/`:

1. `case-7-mitigation-plan-4phase.png` — Agent Space showing the
   4-phase mitigation plan
2. `case-7-spec-full.png` — full agent-ready spec markdown
3. `case-7-claude-code-receiving-spec.png` — Claude Code terminal at
   the moment the spec is pasted
4. `case-7-claude-code-creating-migration.png` — Claude Code writing
   the migration file (mid-execution)
5. `case-7-pr-opened.png` — final GitHub PR page showing the diff and
   the description with incident references
6. `case-7-end-to-end-timeline.png` (optional) — a composed timeline
   from "C2 RCA" → "spec" → "Claude Code" → "PR" (the storytelling shot)

## Recover

```bash
# 1. Stop C2's load generator if it's still running
unset AWS_PROFILE AWS_REGION
cd /Users/ychchen/warren_ws/aws-devops-agent-external-mcp/demo-cases/faults
./recover-L4-unindexed-query-load.sh

# 2. Decide whether to merge the PR
#    - For demo purposes, merging is the most satisfying ending
#      (the agent really did fix the bug, end-to-end)
#    - If you want to repeat C2 without re-introducing the index,
#      close the PR without merging and delete the branch

# 3. If you DID merge, the index now exists. To repeat C2 you must
#    drop it again:
#    psql -h <bjs-todo-db-endpoint> -U <user> -d todo \
#      -c "DROP INDEX IF EXISTS idx_users_email;"
```

## Common pitfalls

- **Skipping C2** — C7 is meaningless without C2's RCA in the
  conversation. The DevOps Agent generates the spec from real
  investigation context. If you start cold, the spec will be generic.
- **Spec is not self-contained** — sometimes the agent's spec
  references "the incident above" without actually inlining the
  RCA contents. The coding agent then has nothing to act on. Force
  self-containment by adding *"Inline the relevant findings from the
  RCA so the spec is standalone."* to the prompt.
- **Coding agent has no push access** — Claude Code can write files
  but cannot push if the repo's GitHub remote uses a token without
  push scope. Verify with `git push` test on a dummy branch before
  the demo. If push fails, the agent ends with "PR ready locally,
  push manually" — still a valid demo, but worse cinema.

## Notes for blog write-up

C7 is the **agentic SRE closed-loop** screenshot AWS uses on its
marquee demos: investigation agent → mitigation plan → coding agent →
PR. We are reproducing it for cn-north-1.

Killer caption candidate:

> *"At T+0 the alarm fires. At T+5min the DevOps Agent posts the RCA
> to Slack. At T+8min it emits a spec. At T+13min Claude Code opens
> a PR. The on-call engineer's job is to **review the PR and click
> merge** — everything else was agents talking to agents."*

For China readers, the angle is: **the bug was investigated in
cn-north-1, the spec was generated cross-partition, the fix was
written by a US-based coding agent, the PR landed in a global GitHub
repo**. The partition boundary is invisible to the loop.
