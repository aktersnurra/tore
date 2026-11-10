defmodule Tore.Repo.Migrations.CreateRecipeIngredients do
  use Ecto.Migration

  def change do
    create table(:recipe_ingredients) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :ingredient_id, references(:ingredients), null: false
      add :quantity, :decimal
      add :unit, :string
      add :notes, :string
      timestamps()
    end

    create index(:recipe_ingredients, [:recipe_id])
  end
end
