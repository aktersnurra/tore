defmodule Tore.Repo.Migrations.CreateTags do
  use Ecto.Migration

  def change do
    create table(:tags) do
      add :name, :string, null: false
      timestamps()
    end

    create unique_index(:tags, [:name])

    create table(:recipe_tags, primary_key: false) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:recipe_tags, [:recipe_id, :tag_id])
  end
end
