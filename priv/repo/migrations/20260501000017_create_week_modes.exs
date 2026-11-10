defmodule Tore.Repo.Migrations.CreateWeekModes do
  use Ecto.Migration

  def change do
    create table(:week_modes) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :mode, :string, null: false, default: "normal"
      add :week_start, :date, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:week_modes, [:household_id, :week_start])
  end
end
