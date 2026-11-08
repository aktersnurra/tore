defmodule Tore.Repo.Migrations.CreateTags do
  use Ecto.Migration

  def change do
    create table(:tags) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :name, :string, null: false
      timestamps()
    end

    create unique_index(:tags, [:household_id, :name])

    create table(:recipe_tags, primary_key: false) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:recipe_tags, [:recipe_id, :tag_id])
  end
end
