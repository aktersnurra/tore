defmodule Tore.Pantry.Learn do
  @moduledoc """
  What a new name means, worked out by pi afterwards. A tick or an add never waits for it: a name
  Tore has never seen gets its ingredient as written at once, and a `learn` job
  (`harness/tasks/learn.md`) then says through `learn_ingredients` whether it is an ingredient the
  household has (*Mellanmjölk* is *Mjölk*: merged into it, the name kept as an alias) or one of its
  own, with its section and shelf life. An ingredient that has a section is learned already, so
  it's never asked about again. A household without pi skips this, and the name stays as written.
  Product names on offers and receipt lines go to the same job (`Tore.Prices.Products`).
  """

  import Ecto.Query

  alias Tore.{Agent, Pi, Repo, Scope}
  alias Tore.Pantry.{IngredientAlias, Match, PantryItem}
  alias Tore.Recipes.{Ingredient, RecipeIngredient}

  @type item :: %{
          name: String.t(),
          same_as: String.t() | nil,
          section: String.t(),
          shelf_life_days: pos_integer() | nil
        }

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
  Asks pi about every name in `names` not learned yet, and waits for it. A name Tore has never
  seen gets its ingredient first, as written.
  """
  @spec names(Scope.t(), [String.t()]) :: :ok
  def names(%Scope{} = scope, names) do
    case unlearned(scope, names) do
      [] -> :ok
      learning -> ask(scope, "Names: " <> Enum.map_join(learning, "; ", & &1.name) <> ".")
    end
  end

  @doc "Runs a `learn` job with `details` (the names or products), and waits for it."
  @spec ask(Scope.t(), String.t()) :: :ok
  def ask(%Scope{} = scope, details) do
    if Pi.check(scope) == :ok, do: Agent.run(scope, "learn", nil, details)
    :ok
  end

  @doc """
  What pi said a name is (`learn_ingredients`): the ingredient it is the same as, which it is
  merged into, or its own section and shelf life. A section Tore doesn't have is kept as other.
  """
  @spec learn(Scope.t(), item()) :: :merged | :filled | {:error, :unknown_name | :unknown_same_as}
  def learn(%Scope{} = scope, %{name: name} = item) do
    with {:ok, ingredient} <- found(scope, name, :unknown_name) do
      case item.same_as && found(scope, item.same_as, :unknown_same_as) do
        nil ->
          fill(ingredient, item)
          :filled

        {:ok, %Ingredient{id: id}} when id == ingredient.id ->
          fill(ingredient, item)
          :filled

        {:ok, into} ->
          {:ok, :ok} = merge(scope, ingredient, into)
          if into.category == nil, do: fill(into, item)
          :merged

        {:error, _} = error ->
          error
      end
    end
  end

  defp found(scope, name, error) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} -> {:ok, ingredient}
      :unknown -> {:error, error}
    end
  end

  @doc """
  The ingredient a product name means, when a barcode is first scanned: one the name already
  matches, or a new one called after the product, which a `learn` job then tidies (merged into
  *Mjölk* for *Arla Mellanmjölk 1,5 %*, its barcode with it).
  """
  @spec product(Scope.t(), String.t()) :: Ingredient.t()
  def product(%Scope{} = scope, product_name) do
    case Match.ingredient(scope, {:name, product_name}) do
      {:ok, ingredient} ->
        ingredient

      :unknown ->
        [ingredient] = new_ingredient(scope, product_name)
        later(scope, [product_name])
        ingredient
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

  # `change/2`, not the changeset, which would re-derive the key.
  defp fill(ingredient, item) do
    section = if item.section in Ingredient.sections(), do: item.section, else: "other"

    ingredient
    |> Ecto.Changeset.change(
      category: section,
      shelf_life_days: ingredient.shelf_life_days || item.shelf_life_days
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
