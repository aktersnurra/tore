defmodule Tore.Repo.Migrations.StoreConfigsByLink do
  use Ecto.Migration

  # A store is now just its link. SQLite can't make a column NOT NULL in place,
  # so rebuild the table. Rows without a link could never be fetched.
  def up do
    create table(:store_configs_new) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :scrape_enabled, :boolean, null: false, default: false
      timestamps()
    end

    execute """
    INSERT INTO store_configs_new (id, name, url, scrape_enabled, inserted_at, updated_at)
    SELECT min(id), name, url, scrape_enabled, inserted_at, updated_at
    FROM store_configs
    WHERE url IS NOT NULL
    GROUP BY url
    """

    drop table(:store_configs)
    rename table(:store_configs_new), to: table(:store_configs)
    create unique_index(:store_configs, [:url])
  end

  def down, do: raise(Ecto.MigrationError, message: "store chain and store_id are gone for good")
end
