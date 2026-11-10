defmodule Tore.Accounts.PendingMember do
  @moduledoc "Someone added to a household by username before their first sign-in."
  use Ecto.Schema
  import Ecto.Changeset

  schema "pending_members" do
    field :username, :string
    field :household_id, :integer
    field :added_by_id, :integer
    timestamps()
  end

  def changeset(pending, attrs) do
    pending
    |> cast(attrs, [:username])
    |> validate_required([:username])
    |> unique_constraint(:username, name: :pending_members_username_household_id_index)
  end
end
