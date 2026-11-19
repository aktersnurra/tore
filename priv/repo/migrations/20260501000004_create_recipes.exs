defmodule Tore.Repo.Migrations.CreateRecipes do
  use Ecto.Migration

  def change do
    create table(:recipes) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :instructions, :text
      add :steps, :text
      add :recipe_type, :string, null: false, default: "meal"
      add :base_servings, :integer
      add :prep_time_minutes, :integer
      add :cook_time_minutes, :integer
      add :source_url, :string
      add :video_url, :string
      add :image_path, :string
      add :last_used_at, :utc_datetime
      add :favorite, :boolean, null: false, default: false
      add :created_by, :integer
      timestamps()
    end

    create index(:recipes, [:household_id])

    # A meal put together from other recipes, its parts in order. The meal follows them: its
    # ingredients are worked out from the parts when it's loaded (`Tore.Recipes`).
    create table(:recipe_parts) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :part_id, references(:recipes, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      timestamps()
    end

    create index(:recipe_parts, [:recipe_id])
    create index(:recipe_parts, [:part_id])
  end
end
