defmodule Tore.Repo.Migrations.CreateHouseholdMemory do
  use Ecto.Migration

  def change do
    create table(:household_memory) do
      add :household_id, references(:households, on_delete: :delete_all), null: false

      add :store, :string,
        null: false,
        check: %{name: "store_is_a_part", expr: "store IN ('profile', 'notes')"}

      add :text, :text, null: false
      add :supersedes_id, references(:household_memory, on_delete: :nilify_all)
      # The run that wrote the entry.
      add :run_id, references(:runs, type: :string, on_delete: :delete_all), null: false
      add :forgotten_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:household_memory, [:household_id, :store],
             where: "forgotten_at IS NULL",
             name: :household_memory_active
           )
  end
end
