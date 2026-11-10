defmodule Tore.Repo.Migrations.CreateHouseholdPreferences do
  use Ecto.Migration

  def change do
    create table(:household_preferences) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :dietary_restrictions, {:array, :string}, default: []
      add :allergies, {:array, :string}, default: []
      timestamps()
    end

    create unique_index(:household_preferences, [:household_id])
  end
end
