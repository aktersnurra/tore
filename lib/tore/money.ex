defmodule Tore.Money do
  @moduledoc "Amounts as people read them: whole kronor, thousands spaced (\"1 850\")."

  @spec format(Decimal.t()) :: String.t()
  def format(%Decimal{} = amount) do
    {sign, digits} =
      case amount |> Decimal.round(0) |> Decimal.to_integer() do
        n when n < 0 -> {"-", Integer.to_string(-n)}
        n -> {"", Integer.to_string(n)}
      end

    spaced =
      digits
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(" ", &Enum.join/1)
      |> String.reverse()

    sign <> spaced
  end
end
