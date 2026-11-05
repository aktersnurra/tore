defmodule Tore.Deals.StoreConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "store_configs" do
    field :name, :string
    field :url, :string
    field :scrape_enabled, :boolean, default: false
    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:name, :url, :scrape_enabled])
    |> validate_required([:name, :url])
    |> unique_constraint(:url)
  end
end
