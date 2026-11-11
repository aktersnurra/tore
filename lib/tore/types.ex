defmodule Tore.Types do
  @moduledoc "Coercions for values that arrive loosely typed, such as model output or decoded JSON."

  @doc """
  A number, a numeric string or a `Decimal` as a `Decimal`. `nil` stays `nil`, and a string
  that doesn't start with a number is `nil` too.

      iex> Tore.Types.decimal(2)
      Decimal.new("2")

      iex> Tore.Types.decimal(1.5)
      Decimal.new("1.5")

      iex> Tore.Types.decimal("89.50")
      Decimal.new("89.50")

      iex> Tore.Types.decimal("2 dl")
      Decimal.new("2")

      iex> Tore.Types.decimal(Decimal.new("3"))
      Decimal.new("3")

      iex> Tore.Types.decimal(nil)
      nil

      iex> Tore.Types.decimal("some")
      nil
  """
  @spec decimal(Decimal.t() | number() | String.t() | nil) :: Decimal.t() | nil
  def decimal(nil), do: nil
  def decimal(%Decimal{} = d), do: d
  def decimal(n) when is_integer(n), do: Decimal.new(n)
  def decimal(n) when is_float(n), do: Decimal.from_float(n)

  def decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _rest} -> d
      :error -> nil
    end
  end
end
