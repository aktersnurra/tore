defmodule Tore.Repo.Migrations.CreateStores do
  use Ecto.Migration

  def change do
    # Shared: a store is fetched once however many households use it.
    create table(:stores) do
      add :name, :string, null: false
      add :url, :string, null: false
      timestamps()
    end

    create unique_index(:stores, [:url])

    create table(:household_stores) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :store_id, references(:stores, on_delete: :delete_all), null: false
      add :scrape_enabled, :boolean, null: false, default: true
      timestamps()
    end

    create unique_index(:household_stores, [:household_id, :store_id])
  end
end
