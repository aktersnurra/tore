defmodule Tore.Repo.Migrations.CreateHouseholdPreferences do
  use Ecto.Migration

  def change do
    create table(:household_preferences) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :dietary_restrictions, {:array, :string}, default: []
      add :allergies, {:array, :string}, default: []
      add :dislikes, {:array, :string}, default: []
      add :cooking_style, {:array, :string}, default: []
      add :cuisine_preferences, :map, default: %{}
      add :default_portions, :integer, default: 4
      add :default_leftover_portions, :integer, default: 2
      add :include_lunches, :boolean, default: false
      add :planning_days, :integer, default: 5
      timestamps()
    end

    create unique_index(:household_preferences, [:household_id])
  end
end
