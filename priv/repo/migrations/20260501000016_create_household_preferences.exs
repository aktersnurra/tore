defmodule Tore.Repo.Migrations.CreateHouseholdPreferences do
  use Ecto.Migration

  def change do
    create table(:household_preferences) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :dietary_restrictions, {:array, :string}, default: []
      add :allergies, {:array, :string}, default: []
      # What a week's shop should cost, unless the week has its own budget.
      add :weekly_budget, :decimal
      timestamps()
    end

    create unique_index(:household_preferences, [:household_id])

    # A week's own budget, set when asked to plan to one.
    create table(:week_budgets) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :week_start, :date, null: false
      add :amount, :decimal, null: false
      timestamps()
    end

    create unique_index(:week_budgets, [:household_id, :week_start])
  end
end
