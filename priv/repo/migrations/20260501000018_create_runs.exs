defmodule Tore.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    # Raw SQL, because SQLite can't add a CHECK to a table once it exists.
    execute(
      """
      CREATE TABLE runs (
        id                TEXT PRIMARY KEY,
        household_id      INTEGER NOT NULL REFERENCES households(id) ON DELETE CASCADE,
        user_id           INTEGER REFERENCES users(id) ON DELETE SET NULL,
        kind              TEXT NOT NULL,
        actor             TEXT NOT NULL,
        surface           TEXT,
        status            TEXT NOT NULL,
        phase             TEXT,
        input             TEXT NOT NULL,
        artifacts         TEXT NOT NULL,
        question          TEXT,
        failure_code      TEXT,
        failure_message   TEXT,
        repair_action     TEXT,
        discard_reason    TEXT,
        undo              TEXT,
        opened_at         TEXT NOT NULL,
        applied_at        TEXT,
        reverted_at       TEXT,
        closed_at         TEXT,
        CHECK (status IN ('running', 'needs_user', 'applied', 'failed', 'reverted', 'discarded')),
        CHECK (status <> 'needs_user' OR question IS NOT NULL),
        CHECK (status <> 'applied'    OR (applied_at IS NOT NULL AND undo IS NOT NULL)),
        CHECK (status <> 'failed'     OR (failure_code IS NOT NULL AND closed_at IS NOT NULL)),
        CHECK (status <> 'reverted'   OR (applied_at IS NOT NULL AND reverted_at IS NOT NULL)),
        CHECK (status <> 'discarded'  OR (discard_reason IS NOT NULL AND closed_at IS NOT NULL))
      )
      """,
      "DROP TABLE runs"
    )

    create index(:runs, [:household_id, :status, :opened_at])
    create index(:runs, [:household_id, :surface, :opened_at])
  end
end
