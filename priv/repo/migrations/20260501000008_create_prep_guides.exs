defmodule Tore.Repo.Migrations.CreatePrepGuides do
  use Ecto.Migration

  def change do
    create table(:prep_guides) do
      add :week_start, :date, null: false
      add :instructions, :text
      add :timeline, :text
      add :cascade_map, :text
      add :storage_notes, :text
      add :daily_assembly, :text
      add :prep_session, :text
      timestamps()
    end

    create unique_index(:prep_guides, [:week_start])
  end
end
