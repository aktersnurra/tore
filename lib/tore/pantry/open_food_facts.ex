defmodule Tore.Pantry.OpenFoodFacts do
  @moduledoc """
  What a barcode is, from Open Food Facts: the open product database, free and with no key. Only
  the number leaves the server. A product's Swedish name is preferred, and its pack (*"1 l"*,
  *"6 x 33 cl"*) is read when it can be.
  """

  @http Application.compile_env(:tore, :http_client)
  @fields "product_name,product_name_sv,quantity"

  @type product :: %{name: String.t(), quantity: Decimal.t() | nil, unit: String.t() | nil}

  @spec product(String.t()) :: {:ok, product()} | :unknown | {:error, term()}
  def product(code) do
    url = "https://world.openfoodfacts.org/api/v2/product/#{code}.json?fields=#{@fields}"

    case @http.fetch(url) do
      {:ok, body} -> body |> decode() |> found()
      {:error, {:http_error, 404}} -> :unknown
      {:error, _} = error -> error
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  defp decode(body) when is_map(body), do: body

  defp found(%{"status" => 1, "product" => product}) do
    case name(product) do
      nil -> :unknown
      name -> {:ok, Map.merge(%{name: name}, pack(product["quantity"]))}
    end
  end

  defp found(_), do: :unknown

  defp name(product) do
    [product["product_name_sv"], product["product_name"]]
    |> Enum.map(&(&1 && String.trim(&1)))
    |> Enum.find(&(&1 not in [nil, ""]))
  end

  @unit ~S"(kg|g|l|dl|cl|ml|st)"
  @number ~S"(\d+(?:[.,]\d+)?)"

  # "1,5 l" → 1.5 l; "6 x 33 cl" → 198 cl. Anything else says nothing about the pack.
  defp pack(text) when is_binary(text) do
    text = text |> String.trim() |> String.downcase()

    cond do
      match = Regex.run(~r/^(\d+)\s*[x×]\s*#{@number}\s*#{@unit}$/u, text) ->
        [_, count, each, unit] = match
        %{quantity: Decimal.mult(Decimal.new(count), number(each)), unit: unit}

      match = Regex.run(~r/^#{@number}\s*#{@unit}$/u, text) ->
        [_, amount, unit] = match
        %{quantity: number(amount), unit: unit}

      true ->
        %{quantity: nil, unit: nil}
    end
  end

  defp pack(_), do: %{quantity: nil, unit: nil}

  defp number(text), do: text |> String.replace(",", ".") |> Decimal.new()
end
