defmodule Tore.Repo.Migrations.CreateWeekModes do
  use Ecto.Migration

  def change do
    create table(:week_modes) do
      add :mode, :string, null: false, default: "normal"
      add :week_start, :date, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:week_modes, [:week_start])
  end
end
