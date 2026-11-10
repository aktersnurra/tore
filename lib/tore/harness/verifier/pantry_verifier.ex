defmodule Tore.Harness.Verifier.PantryVerifier do
  @moduledoc """
  Deterministic verifier for `PantryBeliefUpdate`. Reads current pantry rows
  to enforce monotonic `last_seen_at` per item; no writes, no model calls.

  Checks (SPEC §A.5):
    * provenance set on every item
    * no negative quantities
    * `last_seen_at` monotonic per item (proposed >= current row's)

  Repair action is `:reject`.
  """

  import Ecto.Query

  alias Tore.Harness.Artifact.PantryBeliefUpdate
  alias Tore.Pantry.PantryItem
  alias Tore.Repo

  @type fail_code :: :missing_provenance | :negative_quantity | :last_seen_regressed
  @type repair_action :: :reject

  @spec verify(PantryBeliefUpdate.t(), map()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%PantryBeliefUpdate{items: items}, %{scope: scope}) do
    with :ok <- check_provenance(items),
         :ok <- check_quantities(items),
         :ok <- check_monotonic(scope, items) do
      :ok
    end
  end

  defp check_provenance(items) do
    case Enum.find(items, fn it -> not is_binary(it.provenance) or it.provenance == "" end) do
      nil -> :ok
      _ -> {:fail, :missing_provenance, :reject}
    end
  end

  defp check_quantities(items) do
    bad =
      Enum.any?(items, fn it ->
        case it[:quantity] do
          nil -> false
          %Decimal{} = d -> Decimal.compare(d, Decimal.new(0)) == :lt
          _ -> false
        end
      end)

    if bad, do: {:fail, :negative_quantity, :reject}, else: :ok
  end

  defp check_monotonic(scope, items) do
    names = Enum.map(items, & &1.name)

    current =
      from(p in PantryItem, where: p.name in ^names, select: {p.name, p.last_seen_at})
      |> Repo.all(Tore.Scope.repo_opts(scope))
      |> Map.new()

    regressed =
      Enum.any?(items, fn it ->
        case Map.get(current, it.name) do
          nil -> false
          existing -> DateTime.compare(it.last_seen_at, existing) == :lt
        end
      end)

    if regressed, do: {:fail, :last_seen_regressed, :reject}, else: :ok
  end
end
