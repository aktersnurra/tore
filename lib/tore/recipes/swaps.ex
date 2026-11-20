defmodule Tore.Recipes.Swaps do
  @moduledoc """
  What to use instead of what isn't at home, asked once before cooking. pi picks from what the
  cook says they have and from the pantry, never anything else, and answers per ingredient with
  `suggest_swaps`; the sheet before cooking (`ToreWeb.BeforeCooking`) reads them from its result.

  Nothing is saved: a swap is for this one cook. Having one red onion today says nothing about
  next week, so neither the ticks nor what's typed reach the pantry.
  """

  alias Tore.Scope

  @type t :: %{for: String.t(), use: String.t() | nil, note: String.t() | nil, at_home: boolean()}

  @doc "pi's swaps as sent: trimmed, blanks as nil, and whether each is in the pantry."
  @spec read(Scope.t(), [map()]) :: [t()]
  def read(%Scope{} = scope, answers) do
    Enum.flat_map(answers, fn answer ->
      case is_map(answer) && text(answer["for"]) do
        name when is_binary(name) ->
          use = text(answer["use"])

          [
            %{
              for: name,
              use: use,
              note: text(answer["note"]),
              at_home: use != nil and Tore.Pantry.at_home(scope, [use]).have == [use]
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  A swap for each name in `missing`, in that order, from `swaps` (`read/2`, or the same keys as
  strings from a tool's result). A name pi passed over gets no swap.
  """
  @spec for_missing([String.t()], [map()]) :: [t()]
  def for_missing(missing, swaps) do
    swaps = Enum.map(swaps, &atomize/1)

    for name <- missing do
      swap = Enum.find(swaps, &same?(&1.for, name)) || %{use: nil, note: nil, at_home: false}
      Map.put(swap, :for, name)
    end
  end

  defp atomize(%{"for" => name} = swap),
    do: %{for: name, use: swap["use"], note: swap["note"], at_home: swap["at_home"] == true}

  defp atomize(%{for: _} = swap), do: swap

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
