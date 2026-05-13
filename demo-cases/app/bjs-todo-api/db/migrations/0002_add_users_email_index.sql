-- 0002_add_users_email_index.sql
--
-- Fix migration for the C2 / C9 demo bug.
--
-- This migration EXISTS so the C7 demo can show "Kiro / Claude Code adds
-- the migration that fixes the unindexed query bug found by the agent's
-- RCA." It is intentionally NOT applied automatically at app startup —
-- the production database stays missing this index until a human (or a
-- coding agent acting on an agent-ready spec) deliberately runs it.
--
-- Apply manually after the demo:
--   psql "$DATABASE_URL" -f db/migrations/0002_add_users_email_index.sql

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
