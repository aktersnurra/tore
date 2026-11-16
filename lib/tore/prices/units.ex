defmodule Tore.Prices.Units do
  @moduledoc """
  Quantities in the three units prices are kept in: kg, l and st. Weights and volumes convert
  within themselves; a weight never becomes a volume, and a count never becomes either.
  """

  @type base :: String.t()

  @factors %{
    "g" => {"0.001", "kg"},
    "hg" => {"0.1", "kg"},
    "kg" => {"1", "kg"},
    "ml" => {"0.001", "l"},
    "cl" => {"0.01", "l"},
    "dl" => {"0.1", "l"},
    "l" => {"1", "l"},
    "liter" => {"1", "l"},
    "msk" => {"0.015", "l"},
    "tsk" => {"0.005", "l"},
    "krm" => {"0.001", "l"},
    "st" => {"1", "st"},
    "pcs" => {"1", "st"},
    "stk" => {"1", "st"}
  }

  @doc """
  `quantity` of `unit` in its base unit, or `:unknown` for a unit with none (a pinch, a can). A
  missing unit counts things.
  """
  @spec to_base(Decimal.t(), String.t() | nil) :: {Decimal.t(), base()} | :unknown
  def to_base(%Decimal{} = quantity, unit) do
    case Map.get(@factors, normalise(unit)) do
      {factor, base} -> {Decimal.mult(quantity, Decimal.new(factor)), base}
      nil -> :unknown
    end
  end

  @doc "The base unit `unit` converts to, or nil."
  @spec base(String.t() | nil) :: base() | nil
  def base(unit) do
    case Map.get(@factors, normalise(unit)) do
      {_, base} -> base
      nil -> nil
    end
  end

  defp normalise(nil), do: "st"

  defp normalise(unit) do
    case unit |> String.trim() |> String.downcase() |> String.trim_trailing(".") do
      "" -> "st"
      u -> u
    end
  end
end
