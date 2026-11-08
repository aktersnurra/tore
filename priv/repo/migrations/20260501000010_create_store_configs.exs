defmodule Tore.Repo.Migrations.CreateStoreConfigs do
  use Ecto.Migration

  def change do
    create table(:store_configs) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :scrape_enabled, :boolean, null: false, default: false
      timestamps()
    end

    create unique_index(:store_configs, [:url])
  end
end
