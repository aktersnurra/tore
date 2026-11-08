defmodule Tore.Deals.Store do
  @moduledoc "A store whose offers Tore reads. Shared by every household that uses it."
  use Ecto.Schema
  import Ecto.Changeset

  schema "stores" do
    field :name, :string
    field :url, :string
    timestamps()
  end

  def changeset(store, attrs) do
    store
    |> cast(attrs, [:name, :url])
    |> validate_required([:name, :url])
    |> unique_constraint(:url)
  end
end
