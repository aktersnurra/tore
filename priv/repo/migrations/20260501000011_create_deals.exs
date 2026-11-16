defmodule Tore.Repo.Migrations.CreateDeals do
  use Ecto.Migration

  def change do
    # Shared across households. Ended offers stay for half a year as the price history
    # (`Tore.Deals.clear_expired/0`), so each week's offer is its own row.
    create table(:deals) do
      add :chain, :string, null: false, default: "ica"
      add :store, :string, null: false
      add :store_location, :string
      add :product_name, :string, null: false
      add :brand, :string
      add :size, :string
      # What the offer costs for `quantity` items: "3 för 40 kr" is 40 for 3.
      add :price, :decimal
      add :quantity, :integer, null: false, default: 1
      # What the price is per: "st", "kg" or "l".
      add :price_unit, :string
      # The usual price per item, the low end when the page gives a range.
      add :regular_price, :decimal
      add :comparison_price, :decimal
      add :comparison_unit, :string
      add :offer_condition, :string
      add :valid_from, :date
      add :valid_until, :date, null: false
      add :source, :string, null: false, default: "scraped"
      timestamps()
    end

    create index(:deals, [:store, :valid_until])
    create unique_index(:deals, [:chain, :store, :product_name, :valid_until])
  end
end
