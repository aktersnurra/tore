defmodule Tore.Pantry.Learn do
  @moduledoc """
  The one model call a new name gets. A tick or an add never waits for it: it runs afterwards,
  and an ingredient that has a section is learned already, so it's never asked about again.

  The answer either says the name means an ingredient Tore has (*Mellanmjölk* is *mjölk*), and
  the new ingredient is merged into that one with the name kept as an alias, or it fills the new
  ingredient's section and shelf life. A household without the model skips this, and the name
  stays as written.
  """

  import Ecto.Query

  require Logger

  alias Tore.{Household, Pantry, Repo, Scope}
  alias Tore.Pantry.{IngredientAlias, Match, PantryItem}
  alias Tore.Recipes.{Ingredient, RecipeIngredient}

  @doc """
  Learns `names` after the caller has moved on, then runs `then`, if given. Off in tests
  (`config :tore, :learn`).
  """
  @spec later(Scope.t(), [String.t()], (-> any()) | nil) :: :ok
  def later(%Scope{} = scope, names, then \\ nil) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
        names(scope, names)
        if then, do: then.()
      end)
    end

    :ok
  end

  @doc """
  Learns every name in `names` not learned yet, in one model call. A name Tore has never seen gets
  its ingredient first, as written.
  """
  @spec names(Scope.t(), [String.t()]) :: :ok
  def names(%Scope{} = scope, names) do
    with :ok <- Tore.LLM.check(scope),
         [_ | _] = learning <- unlearned(scope, names),
         {:ok, norms} <-
           Pantry.canonicalise(
             scope,
             Enum.map(learning, &%{raw_name: &1.name}),
             Household.locale(scope),
             Enum.map(learning, & &1.id)
           ) do
      by_name = Map.new(norms, &{&1.raw_name, &1})

      for ingredient <- learning, norm = by_name[ingredient.name], norm != nil do
        case known(scope, norm.matched_key) do
          nil -> fill(ingredient, norm)
          into -> merge(scope, ingredient, into)
        end
      end
    else
      {:error, reason} -> Logger.warning("Couldn't learn #{inspect(names)}: #{inspect(reason)}")
      _ -> :ok
    end

    :ok
  end

  @spec name(Scope.t(), String.t()) :: :ok
  def name(%Scope{} = scope, name), do: names(scope, [name])

  @doc """
  The ingredient a product name means (*Arla Mellanmjölk 1,5 %* → *mjölk*), asked once when a
  barcode is first scanned. A new ingredient gets its section and shelf life from the same answer.
  Without the model, or when the call fails, the product's name is the ingredient, as written.
  """
  @spec product(Scope.t(), String.t()) :: Ingredient.t()
  def product(%Scope{} = scope, product_name) do
    with :ok <- Tore.LLM.check(scope),
         {:ok, [norm | _]} <-
           Pantry.canonicalise(scope, [%{raw_name: product_name}], Household.locale(scope)) do
      known(scope, norm.matched_key) || named(scope, norm.catalogue_name || product_name, norm)
    else
      _ -> named(scope, product_name, nil)
    end
  end

  # The ingredient called `name`, or a new one, filled from `norm` when there is one.
  defp named(scope, name, norm) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} ->
        ingredient

      :unknown ->
        [ingredient] = new_ingredient(scope, name)
        if norm, do: fill(ingredient, norm), else: ingredient
    end
  end

  defp unlearned(scope, names) do
    names
    |> Enum.uniq_by(&Ingredient.to_key/1)
    |> Enum.flat_map(fn name ->
      case Match.ingredient(scope, {:name, name}) do
        {:ok, %Ingredient{category: nil} = ingredient} -> [ingredient]
        {:ok, _learned} -> []
        :unknown -> new_ingredient(scope, name)
      end
    end)
  end

  defp new_ingredient(scope, name) do
    case Ingredient.to_key(name) do
      "" ->
        []

      _ ->
        [
          %Ingredient{household_id: scope.household_id}
          |> Ingredient.changeset(%{name: String.trim(name)})
          |> Repo.insert!()
        ]
    end
  end

  defp known(_scope, key) when key in [nil, ""], do: nil
  defp known(scope, key), do: Repo.get_by(Ingredient, [key: key], Scope.repo_opts(scope))

  # `change/2`, not the changeset, which would re-derive the key.
  defp fill(ingredient, norm) do
    section = if norm.category in Ingredient.sections(), do: norm.category, else: "other"

    ingredient
    |> Ecto.Changeset.change(
      category: section,
      shelf_life_days: ingredient.shelf_life_days || norm.shelf_life_days
    )
    |> Repo.update!()
  end

  # Everything that pointed at `from` points at `into`, and `from`'s name becomes an alias. The
  # pantry holds one row per ingredient, so a row `into` already has wins.
  defp merge(scope, %Ingredient{} = from, %Ingredient{} = into) do
    opts = Scope.repo_opts(scope)

    Repo.transaction(fn ->
      Repo.update_all(
        from(r in RecipeIngredient, where: r.ingredient_id == ^from.id),
        [set: [ingredient_id: into.id]],
        opts
      )

      if Repo.get_by(PantryItem, [ingredient_id: into.id], opts) do
        Repo.delete_all(from(p in PantryItem, where: p.ingredient_id == ^from.id), opts)
      else
        Repo.update_all(
          from(p in PantryItem, where: p.ingredient_id == ^from.id),
          [set: [ingredient_id: into.id, name: String.downcase(into.name)]],
          opts
        )
      end

      Repo.update_all(
        from(a in IngredientAlias, where: a.ingredient_id == ^from.id),
        [set: [ingredient_id: into.id]],
        opts
      )

      Repo.delete!(from)
      :ok = Match.learn_alias(scope, {:name, from.name}, into.id)
    end)
  end
end
