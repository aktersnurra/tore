defmodule Tore.Mcp.Tools.PutTogether do
  @moduledoc "Puts a dinner together from recipes the household has (`Tore.Recipes.put_together/3`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes

  @impl true
  def name, do: "put_together"

  @impl true
  def description,
    do: """
    Puts a dinner together from the household's recipes, its parts in the order given: \
    "entrecote med bearnaise" is a sauce, the meat, fries and a salad. Find the parts with \
    search_recipes; write any that are missing with save_recipe first (recipe_type component), \
    then pass their ids. The meal follows its parts when they change, and its cooking order is \
    written the first time it's cooked. A part can't itself be put together from parts.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "servings" => %{"type" => "integer", "minimum" => 1},
        "part_ids" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 2}
      },
      "required" => ["title", "part_ids"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"title" => title, "part_ids" => ids} = args)
      when is_binary(title) and is_list(ids) do
    attrs = %{title: String.trim(title), servings: args["servings"] || 4, part_ids: ids}

    case Recipes.put_together(scope, attrs) do
      {:ok, meal} ->
        {:ok, %{done: "Put together #{meal.title}.", recipe_id: meal.id}}

      {:error, :too_few_parts} ->
        {:error, "A meal needs at least two parts."}

      {:error, :unknown_parts} ->
        {:error,
         "Some part_ids aren't the household's recipes. Find them with search_recipes, or write them with save_recipe."}

      {:error, :nested} ->
        {:error, "A part can't itself be put together from parts. Pass its parts instead."}

      {:error, %Ecto.Changeset{}} ->
        {:error, "The meal needs a title."}
    end
  end

  def call(_scope, _args),
    do: {:error, "put_together needs title and part_ids, a list of numbers."}
end
