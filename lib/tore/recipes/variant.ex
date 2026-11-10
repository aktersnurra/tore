defmodule Tore.Recipes.Variant do
  @moduledoc """
  Generate a variant of an existing recipe ("simpler", "vegetarian", "for 6")
  as a `RecipeProposal`. Nothing is written to the catalog here — the
  proposal goes to a `:needs_user` card and only
  confirming the run (`Tore.Harness.Kinds.Planner`) turns it into a real recipe
  (SPEC §A.6.1: invented content never auto-commits).
  """

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.LLM
  alias Tore.LLM.Prompts

  @spec build(Tore.Scope.t(), Tore.Recipes.Recipe.t(), String.t(), String.t() | nil) ::
          {:ok, RecipeProposal.t(), LLM.usage()} | {:error, term()}
  def build(%Tore.Scope{} = scope, source_recipe, instruction, locale) do
    {system, user} =
      Prompts.generate_recipe_variant(summarise(source_recipe), instruction, locale)

    case LLM.text(scope, system, user,
           response_format: Prompts.recipe_json_schema(),
           feature: :recipe_variant
         ) do
      {:ok, %{"title" => title} = payload, usage} when is_binary(title) and title != "" ->
        {:ok, to_proposal(payload, source_recipe, instruction), usage}

      {:ok, _payload, _usage} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  # What the model needs to see of the source: the shape of the dish, not our
  # internal ids.
  defp summarise(recipe) do
    %{
      title: recipe.title,
      description: recipe.description,
      base_servings: recipe.base_servings,
      prep_time_minutes: recipe.prep_time_minutes,
      cook_time_minutes: recipe.cook_time_minutes,
      instructions: recipe.instructions,
      ingredients: Enum.map(recipe_ingredients(recipe), &summarise_ingredient/1)
    }
  end

  defp recipe_ingredients(%{recipe_ingredients: ingredients}) when is_list(ingredients),
    do: ingredients

  defp recipe_ingredients(_recipe), do: []

  defp summarise_ingredient(ri) do
    %{
      name: ingredient_name(ri),
      quantity: ri.quantity && Decimal.to_string(ri.quantity),
      unit: ri.unit
    }
  end

  defp ingredient_name(%{ingredient: %{name: name}}), do: name
  defp ingredient_name(_), do: nil

  defp to_proposal(payload, source_recipe, instruction) do
    %RecipeProposal{
      title: payload["title"],
      description: payload["description"],
      instructions: flatten_steps(payload["steps"]),
      base_servings: payload["base_servings"] || source_recipe.base_servings,
      prep_time_minutes: payload["prep_time_minutes"],
      cook_time_minutes: payload["cook_time_minutes"],
      ingredients: Enum.map(payload["ingredients"] || [], &ingredient_from_payload/1),
      tags: payload["tags"] || [],
      source: :generation,
      source_recipe_id: source_recipe.id,
      instruction: instruction
    }
  end

  defp ingredient_from_payload(item) do
    %{
      name: item["item"] || item["name"],
      quantity: quantity_to_string(item["quantity"]),
      unit: item["unit"]
    }
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp quantity_to_string(n) when is_float(n), do: n |> Float.round(2) |> Float.to_string()
  defp quantity_to_string(s) when is_binary(s), do: s

  defp flatten_steps(nil), do: nil
  defp flatten_steps([]), do: nil

  defp flatten_steps(steps) when is_list(steps) do
    steps
    |> Enum.sort_by(& &1["order"])
    |> Enum.map_join("\n", & &1["action"])
  end
end
