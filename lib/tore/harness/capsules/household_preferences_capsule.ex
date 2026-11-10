defmodule Tore.Harness.Capsules.HouseholdPreferencesCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Household

  defstruct [:guidance]

  @type t :: %__MODULE__{guidance: String.t() | nil}

  @impl true
  def build(ctx) do
    prefs = Household.get_preferences(Tore.Scope.for_household(ctx.household_id))
    guidance = Household.prefs_to_dietary_guidance(prefs)
    %__MODULE__{guidance: guidance}
  end

  @impl true
  def to_prompt(%__MODULE__{guidance: nil}), do: nil
  def to_prompt(%__MODULE__{guidance: guidance}), do: "Household preferences: #{guidance}."
end
