defmodule Tore.Repo.Migrations.CreateIngredients do
  use Ecto.Migration

  def change do
    create table(:ingredients) do
      add :name, :string, null: false
      add :key, :string
      add :category, :string
      add :default_unit, :string
      add :shelf_life_days, :integer
      timestamps()
    end

    create unique_index(:ingredients, [:name])
    create unique_index(:ingredients, [:key])
  end
end
