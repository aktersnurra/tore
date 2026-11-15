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

  @doc "Learns `names` after the caller has moved on. Off in tests (`config :tore, :learn`)."
  @spec later(Scope.t(), [String.t()]) :: :ok
  def later(%Scope{} = scope, names) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
        Enum.each(names, &name(scope, &1))
      end)
    end

    :ok
  end

  @spec name(Scope.t(), String.t()) :: :ok
  def name(%Scope{} = scope, name) do
    with {:ok, %Ingredient{category: nil} = ingredient} <- Match.ingredient(scope, {:name, name}),
         :ok <- Tore.LLM.check(scope),
         {:ok, [norm | _]} <-
           Pantry.canonicalise(
             scope,
             [%{raw_name: ingredient.name}],
             Household.locale(scope),
             ingredient.id
           ) do
      case known(scope, norm.matched_key) do
        nil -> fill(ingredient, norm)
        into -> merge(scope, ingredient, into)
      end
    else
      {:error, reason} -> Logger.warning("Couldn't learn #{inspect(name)}: #{inspect(reason)}")
      _ -> :ok
    end

    :ok
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
