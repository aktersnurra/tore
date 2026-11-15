defmodule Tore.Repo.Migrations.CreateIngredients do
  use Ecto.Migration

  def change do
    create table(:ingredients) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key, :string
      add :category, :string
      add :default_unit, :string
      add :shelf_life_days, :integer
      timestamps()
    end

    create unique_index(:ingredients, [:household_id, :name])
    create unique_index(:ingredients, [:household_id, :key])

    # Other names and barcodes Tore has learned for an ingredient: a name key, or `ean:<digits>`.
    create table(:ingredient_aliases) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :alias, :string, null: false
      add :ingredient_id, references(:ingredients, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:ingredient_aliases, [:household_id, :alias])
  end
end
