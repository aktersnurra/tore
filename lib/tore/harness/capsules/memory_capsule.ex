defmodule Tore.Harness.Capsules.MemoryCapsule do
  @moduledoc """
  The household's memory, both parts in full with how full each is (`Tore.Household.Memory`).
  Capsules are composed once per turn, so this is the turn's frozen snapshot.
  """

  @behaviour Tore.Harness.Capsule

  defstruct [:snapshot]

  @type t :: %__MODULE__{snapshot: String.t() | nil}

  @impl true
  def build(ctx),
    do: %__MODULE__{
      snapshot: Tore.Household.Memory.snapshot(Tore.Scope.for_household(ctx.household_id))
    }

  @impl true
  def to_prompt(%__MODULE__{snapshot: snapshot}), do: snapshot
end
