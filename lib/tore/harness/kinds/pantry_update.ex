defmodule Tore.Harness.Kinds.PantryUpdate do
  @moduledoc """
  Items go into the pantry when they are seen at home (pi reading a photo of a shelf or the
  fridge), from a ticked shopping item, a scanned barcode, or by hand, and come out by hand.
  `ctx` holds `:channel` (`:seen`, `:grocery_checkoff`, `:barcode` or `:manual`) and `:items`.
  An item with an `:item_id` removes that row. A seen item's quantity is what's there now, and it
  may carry a printed `:expires_on` and a `:shelf_life_days` guess (`Tore.Pantry.upsert_belief/2`).

  No name asks a model: `Tore.Pantry.Match` lands it on the ingredient with its key or a name
  learned for one, and an unknown name is kept as written, so `Tore.Pantry.upsert_belief/2`
  creates it. `Tore.Pantry.Learn` learns it later, once. `verify` refuses a key the household
  doesn't have, so an invented key never creates one. It applies straight away, and undo puts
  each item back as it was.
  """

  @behaviour Tore.Harness.Kind

  import Ecto.Query

  alias Tore.{Pantry, Repo, Scope}
  alias Tore.Pantry.Match
  alias Tore.Harness.Artifact.PantryBeliefUpdate
  alias Tore.Harness.Verifier.PantryVerifier
  alias Tore.Recipes.Ingredient

  @impl true
  def kind, do: "pantry_belief_update_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(ctx), do: %{input: %{"channel" => Atom.to_string(ctx.channel)}, actor: :user}

  @impl true
  def propose(_run, %{channel: channel, items: items}) when is_list(items),
    do: {:ok, artifact(items, channel)}

  @impl true
  def resolve(%PantryBeliefUpdate{items: items} = update, %{scope: scope}),
    do: {:ok, %{update | items: Enum.map(items, &matched(scope, &1))}}

  # A name Tore knows lands on its ingredient, with no model.
  defp matched(scope, %{change: :added, name: name} = item) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} ->
        Map.merge(item, %{catalogue_name: ingredient.name, matched_key: ingredient.key})

      :unknown ->
        item
    end
  end

  defp matched(_scope, item), do: item

  @impl true
  def verify(%PantryBeliefUpdate{items: items} = update, %{scope: scope}) do
    with :ok <- PantryVerifier.verify(update, %{scope: scope}) do
      claimed = items |> Enum.map(& &1[:matched_key]) |> Enum.reject(&(&1 in [nil, ""]))

      known =
        Repo.all(
          from(i in Ingredient, where: i.key in ^claimed, select: i.key),
          Scope.repo_opts(scope)
        )

      if Enum.all?(claimed, &(&1 in known)), do: :ok, else: {:fail, :unknown_ingredient, :reject}
    end
  end

  @impl true
  def review_question(_update), do: nil

  @impl true
  def apply_proposal(%PantryBeliefUpdate{items: items} = update, %{scope: scope}) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, steps} ->
      case write(scope, item) do
        {:ok, row, :added, nil} ->
          {:cont, {:ok, [{:restore_pantry_item, row.id, :absent} | steps]}}

        {:ok, row, change, before} when change in [:bumped, :removed] ->
          {:cont, {:ok, [{:restore_pantry_item, row.id, before} | steps]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, {:steps, Enum.reverse(steps)}, [update]}
      error -> error
    end
  end

  defp write(scope, %{change: :removed, item_id: id}) do
    case Repo.get(Tore.Pantry.PantryItem, id, Scope.repo_opts(scope)) do
      nil ->
        {:error, :not_found}

      row ->
        :ok = Pantry.remove_item(scope, id)
        {:ok, row, :removed, Pantry.before_image(row)}
    end
  end

  defp write(scope, item), do: Pantry.upsert_belief(scope, item)

  # Each line is marked with where it came from.
  defp artifact(items, channel) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %PantryBeliefUpdate{
      items:
        Enum.map(items, fn it ->
          %{
            name: it[:name] || it["name"],
            change: if(it[:item_id], do: :removed, else: :added),
            quantity: it[:quantity] || it["quantity"],
            unit: it[:unit] || it["unit"],
            pack_size: it[:pack_size],
            category: it[:category] || it["category"],
            expires_on: it[:expires_on],
            shelf_life_days: it[:shelf_life_days],
            provenance: provenance(channel),
            last_seen_at: now,
            item_id: it[:item_id]
          }
        end)
    }
  end

  defp provenance(:grocery_checkoff), do: "grocery_checkoff"
  defp provenance(:manual), do: "manual"
  # Seen at home: what's there now, as a photo shows it.
  defp provenance(:seen), do: "vision"
  defp provenance(:barcode), do: "barcode"
end
