defmodule Tore.Chef.CookedDinner do
  @moduledoc "A dinner marked Done in the cook view; `rescued` when it used food near its date."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "cooked_dinners" do
    field :household_id, :integer
    field :recipe_id, :integer
    field :cooked_on, :date
    field :rescued, :boolean, default: false
    timestamps(updated_at: false)
  end
end
