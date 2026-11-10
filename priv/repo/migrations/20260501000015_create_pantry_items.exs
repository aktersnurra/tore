defmodule Tore.Repo.Migrations.CreatePantryItems do
  use Ecto.Migration

  def change do
    create table(:pantry_items) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :quantity, :decimal
      add :unit, :string
      add :category, :string
      add :ingredient_id, references(:ingredients, on_delete: :nilify_all)
      add :added_at, :date, null: false
      add :expires_at, :date
      add :expires_source, :string
      add :provenance, :string, null: false, default: "manual"
      add :belief, :string, null: false, default: "confirmed"
      add :last_seen_at, :utc_datetime
      timestamps()
    end

    create index(:pantry_items, [:household_id])
    # One row per ingredient in a household. Rows with no ingredient aren't limited.
    create unique_index(:pantry_items, [:household_id, :ingredient_id])
  end
end
