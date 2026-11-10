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
  end
end
