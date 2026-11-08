defmodule Tore.Harness.Capsules.PantryBeliefsCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Pantry

  @use_soon_days 3

  defstruct names: [], use_soon: [], total: 0

  @type t :: %__MODULE__{
          names: [String.t()],
          use_soon: [String.t()],
          total: non_neg_integer()
        }

  @impl true
  def build(ctx) do
    items = Pantry.list_usable(Tore.Scope.for_household(ctx.household_id))
    use_soon = items |> Enum.filter(&use_soon?/1) |> Enum.sort_by(& &1.expires_at, Date)
    names = Enum.map(use_soon ++ (items -- use_soon), & &1.name) |> Enum.take(20)

    %__MODULE__{names: names, use_soon: Enum.map(use_soon, & &1.name), total: length(items)}
  end

  @impl true
  def to_prompt(%__MODULE__{names: []}), do: nil

  def to_prompt(%__MODULE__{names: names, use_soon: use_soon, total: total}) do
    overflow = if total > 20, do: " and #{total - 20} more", else: ""
    "Pantry has: #{Enum.join(names, ", ")}#{overflow}." <> use_soon_clause(use_soon)
  end

  defp use_soon_clause([]), do: ""
  defp use_soon_clause(names), do: " Use soon: #{Enum.join(names, ", ")}."

  defp use_soon?(%{expires_at: %Date{} = expires_at}),
    do: Date.diff(expires_at, Date.utc_today()) <= @use_soon_days

  defp use_soon?(_item), do: false
end
