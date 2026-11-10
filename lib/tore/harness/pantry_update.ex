defmodule Tore.Harness.PantryUpdate do
  @moduledoc """
  Pure helpers for `:pantry_belief_update_run` (SPEC §4).

  Three input channels feed this run:

    * `:grocery_checkoff` — grocery list item checked off
    * `:manual`           — user added/edited an item by hand
    * `:shelf_photo`      — photo of what's on a shelf, read by the vision model

  All channels apply straight away and can be undone. They normalise to a flat
  `[%{name, quantity, unit, category, ...}]` list, run it through the LLM
  canonicaliser, then atomically upsert pantry beliefs (find-or-create
  ingredient, find-or-create-or-bump pantry row).
  """

  alias Tore.Harness.Artifact.PantryBeliefUpdate, as: Artifact
  alias Tore.Pantry

  @spec parse_shelf_photo(Tore.Scope.t(), binary()) :: {:ok, [map()]} | {:error, term()}
  def parse_shelf_photo(scope, image_binary) do
    Pantry.parse_image(scope, image_binary)
  end

  @doc """
  Build the `PantryBeliefUpdate` artifact from raw items + a channel, marking
  each line with the appropriate provenance.
  """
  @spec build_artifact([map()], atom()) :: Artifact.t()
  def build_artifact(items, channel) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    provenance = provenance_for(channel)

    %Artifact{
      items:
        Enum.map(items, fn it ->
          %{
            name: it[:name] || it["name"],
            change: :added,
            quantity: it[:quantity] || it["quantity"],
            unit: it[:unit] || it["unit"],
            category: it[:category] || it["category"],
            expires_on: it[:expires_on],
            provenance: provenance,
            last_seen_at: now
          }
        end)
    }
  end

  defp provenance_for(:grocery_checkoff), do: "grocery_checkoff"
  defp provenance_for(:manual), do: "manual"
  defp provenance_for(:shelf_photo), do: "vision"

  @doc """
  Canonicalise the artifact items via the LLM, then atomically upsert each
  belief. Returns `{:ok, counts, snapshots}` where counts is `%{added: n,
  bumped: n}` and snapshots is `[%{item_id, before, after}]` capturing the
  pre-mutation state of each affected row (`before == nil` for newly
  created rows). The snapshots feed `PantrySnapshot` so the run can undo.
  """
  @spec apply!(Tore.Scope.t(), Artifact.t(), String.t() | nil) ::
          {:ok, map(), [map()]} | {:error, term()}
  def apply!(_scope, %Artifact{items: []}, _locale), do: {:ok, %{added: 0, bumped: 0}, []}

  def apply!(scope, %Artifact{items: items}, locale) do
    raws = Enum.map(items, &%{raw_name: &1.name})

    with {:ok, norms} <- Pantry.canonicalise(scope, raws, locale) do
      indexed = Map.new(norms, fn n -> {n.raw_name, n} end)

      Tore.Repo.transaction(fn ->
        Enum.reduce(items, {%{added: 0, bumped: 0}, []}, fn it, {counts, snaps} ->
          attrs = merge_norm(it, Map.get(indexed, it.name))

          case Pantry.upsert_belief(scope, attrs) do
            {:ok, item, :added, _before} ->
              {Map.update!(counts, :added, &(&1 + 1)),
               [%{item_id: item.id, before: nil, after: snapshot_of(item)} | snaps]}

            {:ok, item, :bumped, before} ->
              {Map.update!(counts, :bumped, &(&1 + 1)),
               [%{item_id: item.id, before: before, after: snapshot_of(item)} | snaps]}

            {:error, reason} ->
              Tore.Repo.rollback(reason)
          end
        end)
      end)
      |> case do
        {:ok, {counts, snaps}} -> {:ok, counts, Enum.reverse(snaps)}
        {:error, _} = err -> err
      end
    end
  end

  defp snapshot_of(item) do
    %{
      quantity: item.quantity && Decimal.to_string(item.quantity),
      unit: item.unit,
      last_seen_at: item.last_seen_at,
      provenance: item.provenance,
      belief: item.belief,
      added_at: item.added_at,
      expires_at: item.expires_at,
      expires_source: item.expires_source
    }
  end

  defp merge_norm(it, nil), do: it

  defp merge_norm(it, n) do
    it
    |> Map.put(:catalogue_name, n.catalogue_name || it.name)
    |> Map.put(:matched_key, n.matched_key)
    |> Map.put(:category, it[:category] || n.category)
    |> Map.put(:default_unit, n.default_unit)
    |> Map.put(:shelf_life_days, n[:shelf_life_days])
  end
end
