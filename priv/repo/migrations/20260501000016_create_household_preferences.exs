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

    # What the household buys regularly beyond its dinners, added to the list when it's due.
    create table(:basics) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :ingredient_id, references(:ingredients, on_delete: :delete_all), null: false
      add :interval_days, :integer, null: false
      # "learned" from what was bought, or "asked" for in Capture or over MCP.
      add :source, :string, null: false
      add :quantity, :decimal
      add :unit, :string
      add :last_bought, :date
      # Removals from the list in a row; three stop it.
      add :removals, :integer, null: false, default: 0
      add :stopped, :boolean, null: false, default: false
      timestamps()
    end

    create unique_index(:basics, [:household_id, :ingredient_id])
  end
end
