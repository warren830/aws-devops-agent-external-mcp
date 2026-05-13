-- 0001_initial.sql
-- Bootstrap schema for bjs-todo-api.
--
-- WARNING (intentional): users.email has NO index on it. The C2 / C9 demo
-- cases rely on `GET /api/users/search?email=...` issuing a sequential scan
-- once the table grows past ~10k rows. The fix migration that ADDS the
-- index lives in 0002_add_users_email_index.sql and is intentionally NOT
-- applied at startup.

CREATE TABLE IF NOT EXISTS users (
    id          SERIAL PRIMARY KEY,
    email       TEXT NOT NULL,
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS todos (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    completed   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Helpful, non-bug-related index for the FK lookup on todos.
CREATE INDEX IF NOT EXISTS idx_todos_user_id ON todos(user_id);
