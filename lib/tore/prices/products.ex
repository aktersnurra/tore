defmodule Tore.Prices.Products do
  @moduledoc """
  Matches the products on deals and receipt lines to the household's ingredients, once per name.

  A name with an ingredient's own key, or a name the pantry has learned, matches for free.
  Otherwise one model call matches a batch of names against the household's ingredients
  (`Tore.Pantry.canonicalise/4`), and only a key the household really has counts. "None fits"
  is stored too, and asked again after four weeks, since the household may have the ingredient
  by then.

  Matches live in their own table, never in the pantry's aliases: a wrong one nudges a price,
  and can't change the pantry or the shopping list.
  """

  import Ecto.Query

  require Logger

  alias Tore.{Household, Pantry, Repo, Scope}
  alias Tore.Prices.ProductMatch
  alias Tore.Recipes.Ingredient

  @none_kept_days 28

  @doc """
  Matches `names` after the caller has moved on. `model: false` matches only what's free, as for
  a receipt logged over MCP, which never reaches the server's model. Off in tests
  (`config :tore, :learn`).
  """
  @spec later(Scope.t(), [String.t()], keyword()) :: :ok
  def later(%Scope{} = scope, names, opts \\ []) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> match(scope, names, opts) end)
    end

    :ok
  end

  @doc "Matches every name in `names` not matched yet. Without the model only free matches are made."
  @spec match(Scope.t(), [String.t()], keyword()) :: :ok
  def match(%Scope{} = scope, names, opts \\ []) do
    names = names |> Enum.uniq_by(&key/1) |> Enum.reject(&(key(&1) == ""))
    known = lookup(scope, names)
    unmatched = Enum.reject(names, &Map.has_key?(known, key(&1)))

    unmatched =
      Enum.reject(unmatched, fn name ->
        case Pantry.Match.ingredient(scope, {:name, name}) do
          {:ok, ingredient} -> store(scope, name, ingredient.id)
          :unknown -> false
        end
      end)

    if unmatched != [] and Keyword.get(opts, :model, true) and Tore.LLM.check(scope) == :ok,
      do: ask_model(scope, unmatched)

    :ok
  end

  @doc """
  The ingredient each of `names` is matched to, by the name's key: an ingredient id, or nil when
  none fits. A name not matched yet is absent.
  """
  @spec lookup(Scope.t(), [String.t()]) :: %{String.t() => integer() | nil}
  def lookup(%Scope{} = scope, names) do
    keys = Enum.map(names, &key/1)
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@none_kept_days, :day)

    from(m in ProductMatch,
      where: m.product_key in ^keys,
      where: not is_nil(m.ingredient_id) or m.updated_at > ^cutoff,
      select: {m.product_key, m.ingredient_id}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Map.new()
  end

  @doc """
  Stores what someone's own Claude matched (`match_deals` over MCP): `ingredient_id` nil when none
  fits. Only the household's own ingredients count.
  """
  @spec put(Scope.t(), String.t(), integer() | nil) :: :ok | {:error, :unknown_ingredient}
  def put(%Scope{} = scope, name, nil), do: store_ok(scope, name, nil)

  def put(%Scope{} = scope, name, ingredient_id) do
    case Repo.get(Ingredient, ingredient_id, Scope.repo_opts(scope)) do
      nil -> {:error, :unknown_ingredient}
      _ -> store_ok(scope, name, ingredient_id)
    end
  end

  defp store_ok(scope, name, id) do
    store(scope, name, id)
    :ok
  end

  defp ask_model(scope, names) do
    ids = Map.new(Repo.all(Ingredient, Scope.repo_opts(scope)), &{&1.key, &1.id})
    if map_size(ids) > 0, do: ask_model(scope, names, ids)
  end

  # Nothing to match against means nothing to ask.
  defp ask_model(scope, names, ids) do
    case Pantry.canonicalise(scope, Enum.map(names, &%{raw_name: &1}), Household.locale(scope)) do
      {:ok, norms} ->
        by_name = Map.new(norms, &{&1.raw_name, &1.matched_key})
        for name <- names, Map.has_key?(by_name, name), do: store(scope, name, ids[by_name[name]])

      {:error, reason} ->
        Logger.warning("Couldn't match products #{inspect(names)}: #{inspect(reason)}")
    end
  end

  defp store(scope, name, ingredient_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(
      %ProductMatch{
        household_id: scope.household_id,
        product_key: key(name),
        ingredient_id: ingredient_id,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [ingredient_id: ingredient_id, updated_at: now]],
      conflict_target: [:household_id, :product_key]
    )

    true
  end

  defp key(name), do: Ingredient.to_key(name)
end
