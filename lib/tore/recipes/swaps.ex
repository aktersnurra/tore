defmodule Tore.Recipes.Swaps do
  @moduledoc """
  What to use instead of what isn't at home, asked once before cooking. The model picks from what
  the cook says they have and from the pantry, never anything else, and answers per ingredient.

  Nothing is saved: a swap is for this one cook. Having one red onion today says nothing about
  next week, so neither the ticks nor what's typed reach the pantry.
  """

  alias Tore.Recipes.Recipe
  alias Tore.Scope

  @type t :: %{for: String.t(), use: String.t() | nil, note: String.t() | nil, at_home: boolean()}

  @doc """
  A swap for each name in `missing`, in that order. `offered` is what the cook typed they have
  ("rödlök, gräddfil"), or "". `at_home` says the swap is in the pantry. One model call, whatever
  the number of names.
  """
  @spec check(Scope.t(), Recipe.t(), [String.t()], String.t()) :: {:ok, [t()]} | {:error, term()}
  def check(%Scope{} = scope, %Recipe{} = recipe, [_ | _] = missing, offered)
      when is_binary(offered) do
    pantry = scope |> Tore.Pantry.list_usable() |> Enum.map(& &1.name) |> Enum.uniq()

    payload = %{
      recipe: %{
        title: recipe.title,
        ingredients: Enum.map(recipe.recipe_ingredients, &ingredient/1),
        instructions: recipe.instructions
      },
      missing: missing,
      they_have: String.trim(offered),
      pantry: pantry
    }

    {system, user} = Tore.LLM.Prompts.swaps(payload, Tore.Household.locale(scope))

    case Tore.LLM.text(scope, system, user,
           response_format: Tore.LLM.Prompts.swaps_schema(),
           feature: :suggest_substitution
         ) do
      {:ok, %{"swaps" => answers}, _usage} when is_list(answers) ->
        {:ok, Enum.map(missing, &swap(&1, answers, scope))}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  defp ingredient(ri) do
    Enum.join(
      [ri.quantity && Decimal.to_string(ri.quantity, :normal), ri.unit, ri.ingredient.name]
      |> Enum.reject(&(&1 in [nil, ""])),
      " "
    )
  end

  # The model's answer for `name`; an ingredient it skipped gets no swap.
  defp swap(name, answers, scope) do
    answer = Enum.find(answers, &(is_map(&1) and same?(&1["for"], name))) || %{}
    use = text(answer["use"])

    %{
      for: name,
      use: use,
      note: text(answer["note"]),
      at_home: use != nil and Tore.Pantry.at_home(scope, [use]).have == [use]
    }
  end

  defp same?(a, b) when is_binary(a), do: String.downcase(String.trim(a)) == String.downcase(b)
  defp same?(_a, _b), do: false

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil
end
