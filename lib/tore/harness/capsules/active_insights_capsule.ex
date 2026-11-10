defmodule Tore.Harness.Capsules.ActiveInsightsCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Household

  defstruct bodies: []

  @type t :: %__MODULE__{bodies: [String.t()]}

  @impl true
  def build(ctx) do
    bodies =
      Household.list_active_insights(Tore.Scope.for_household(ctx.household_id))
      |> Enum.take(5)
      |> Enum.map(& &1.body)

    %__MODULE__{bodies: bodies}
  end

  @impl true
  def to_prompt(%__MODULE__{bodies: []}), do: nil

  def to_prompt(%__MODULE__{bodies: bodies}) do
    lines = Enum.map_join(bodies, "\n", fn body -> "- #{body}" end)
    "Household patterns:\n#{lines}"
  end
end
