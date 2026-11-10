defmodule Tore.Repo.Migrations.CreatePrepGuides do
  use Ecto.Migration

  def change do
    create table(:prep_guides) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :week_start, :date, null: false
      add :instructions, :text
      add :timeline, :text
      add :cascade_map, :text
      add :storage_notes, :text
      add :daily_assembly, :text
      add :prep_session, :text
      timestamps()
    end

    create unique_index(:prep_guides, [:household_id, :week_start])
  end
end
