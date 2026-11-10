defmodule Tore.Harness.Kinds.PantryUpdate do
  @moduledoc """
  Items go into the pantry from a shelf photo, a ticked shopping item, or by hand, and come out
  by hand. `ctx` holds `:channel` (`:shelf_photo`, `:grocery_checkoff` or `:manual`), and
  `:image_binary` for a photo or `:items` otherwise. An item with an `:item_id` removes that row.

  `resolve` sends the names through the LLM canonicaliser, and `verify` refuses an answer that
  names a catalogue ingredient the household doesn't have, so an invented key never creates one.
  It applies straight away, and undo puts each item back as it was.
  """

  @behaviour Tore.Harness.Kind

  import Ecto.Query

  alias Tore.{Household, Pantry, Repo, Scope}
  alias Tore.Harness.Artifact.PantryBeliefUpdate
  alias Tore.Harness.Verifier.PantryVerifier
  alias Tore.Recipes.Ingredient

  @no_usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  @impl true
  def kind, do: "pantry_belief_update_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(ctx), do: %{input: %{"channel" => Atom.to_string(ctx.channel)}, actor: :user}

  @impl true
  def propose(_run, %{channel: :shelf_photo, scope: scope, image_binary: image}) do
    with {:ok, items} <- Pantry.parse_image(scope, image) do
      {:ok, artifact(items, :shelf_photo), @no_usage}
    end
  end

  def propose(_run, %{channel: channel, items: items}) when is_list(items),
    do: {:ok, artifact(items, channel), @no_usage}

  @impl true
  def resolve(%PantryBeliefUpdate{items: items} = update, %{scope: scope}) do
    # Only additions need a catalogue name; a removal names a row already there.
    case for(%{change: :added, name: name} <- items, do: %{raw_name: name}) do
      [] ->
        {:ok, update}

      raws ->
        with {:ok, norms} <- Pantry.canonicalise(scope, raws, Household.locale(scope)) do
          by_name = Map.new(norms, &{&1.raw_name, &1})
          {:ok, %{update | items: Enum.map(items, &resolved(&1, by_name[&1.name]))}}
        end
    end
  end

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

  defp resolved(%{change: :removed} = item, _norm), do: item
  defp resolved(item, nil), do: item

  defp resolved(item, norm) do
    Map.merge(item, %{
      catalogue_name: norm.catalogue_name || item.name,
      matched_key: norm.matched_key,
      category: item[:category] || norm.category,
      default_unit: norm.default_unit,
      shelf_life_days: norm[:shelf_life_days]
    })
  end

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
            category: it[:category] || it["category"],
            expires_on: it[:expires_on],
            provenance: provenance(channel),
            last_seen_at: now,
            item_id: it[:item_id]
          }
        end)
    }
  end

  defp provenance(:grocery_checkoff), do: "grocery_checkoff"
  defp provenance(:manual), do: "manual"
  defp provenance(:shelf_photo), do: "vision"
end
