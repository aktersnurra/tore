defmodule Tore.Deals.Parsers.ICA do
  @behaviour Tore.Deals.Parsers.Parser

  @impl Tore.Deals.Parsers.Parser
  def hosts, do: ["www.ica.se", "ica.se"]

  @impl Tore.Deals.Parsers.Parser
  def chain, do: "ica"

  @impl Tore.Deals.Parsers.Parser
  def store_name(%URI{path: path}) do
    case Regex.run(~r{^/erbjudanden/ica-([a-z0-9-]+)-\d+/?$}, path || "") do
      [_, slug] ->
        {:ok, "ICA " <> (slug |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1))}

      _ ->
        {:error, :unsupported_store}
    end
  end

  @impl Tore.Deals.Parsers.Parser
  def canonical_url(%URI{path: path}),
    do: "https://www.ica.se" <> String.trim_trailing(path, "/") <> "/"

  @impl Tore.Deals.Parsers.Parser
  def parse(html) do
    with {:ok, offers} <- extract_initial_data(html),
         {:ok, offers} <- extract_offers(offers) do
      deals = Enum.map(offers, &to_deal/1)
      {:ok, deals}
    end
  end

  defp extract_initial_data(html) do
    # ICA's SPA embeds offers directly in the SSR HTML as __INITIAL_DATA__.
    # We extract only the weeklyOffers array to avoid parsing the full (invalid) JSON blob.
    case Regex.run(~r/"weeklyOffers":(\[.+?\]),"compensationOffersStatus"/s, html) do
      [_, arr_str] ->
        cleaned = String.replace(arr_str, ":undefined", ":null")
        Jason.decode(cleaned)

      _ ->
        {:error, :no_initial_data}
    end
  end

  defp extract_offers(offers) when is_list(offers), do: {:ok, offers}
  defp extract_offers(_), do: {:error, :no_offers}

  defp to_deal(offer) do
    details = offer["details"] || %{}
    mechanics = offer["parsedMechanics"] || %{}
    store = List.first(offer["stores"] || []) || %{}

    # The offer as the page words it ("3 för 40 kr", "39,90 kr/st"), or composed from the
    # parsed mechanics when it isn't given. The price is read from these words: the parsed
    # mechanics split off the öre.
    condition =
      nilify(details["mechanicInfo"]) ||
        nilify(
          "#{mechanics["value1"]} #{mechanics["value2"]} kr#{mechanics["value4"]}"
          |> String.trim()
        )

    {price, quantity, unit} = parse_offer(condition)

    # The comparison price, e.g. "87:50/kg" or "412:50-495:00/kg u. spad".
    {comparison_price, comparison_unit} = parse_comparison(offer["comparisonPrice"])

    store_name = nilify(store["storeMarketingName"]) || "ICA"

    %{
      chain: "ica",
      store: store_name,
      store_location: store_name,
      product_name: details["name"] || "",
      brand: nilify(details["brand"]),
      size: nilify(details["packageInformation"]),
      price: price,
      quantity: quantity,
      price_unit: unit,
      offer_condition: condition,
      # From the store entry, e.g. "52,89-57,83" or "267".
      regular_price: low_end(store["regularPrice"]),
      comparison_price: comparison_price,
      comparison_unit: comparison_unit,
      valid_until: parse_date(offer["validTo"]),
      source: :scraped
    }
  end

  @amount ~S"(\d+(?:[,.:]\d+)?)"

  # "39,90 kr/st", "3 för 40 kr", "79 kr/kg". An offer that only says what you save ("Spara
  # 10 kr", "20% rabatt") or how many you get ("Köp 3 betala för 2") has no price.
  defp parse_offer(nil), do: {nil, 1, nil}

  defp parse_offer(condition) do
    with false <- condition =~ ~r/spara|rabatt|%/iu,
         [_, count, amount | unit] <-
           Regex.run(
             ~r/(?:(\d+)\s*(?:st\s*)?för\s*)?#{@amount}\s*kr(?:\s*\/\s*(\p{L}+))?/iu,
             condition
           ) do
      quantity = if count == "", do: 1, else: String.to_integer(count)
      {to_decimal(amount), quantity, unit(List.first(unit))}
    else
      _ -> {nil, 1, nil}
    end
  end

  defp parse_comparison(nil), do: {nil, nil}

  defp parse_comparison(text) do
    case Regex.run(~r/^#{@amount}(?:-[\d,.:]+)?\s*\/\s*(\p{L}+)/u, String.trim(text)) do
      [_, amount, unit] -> {to_decimal(amount), unit(unit)}
      _ -> {nil, nil}
    end
  end

  defp low_end(nil), do: nil

  defp low_end(text) do
    case Regex.run(~r/^\s*#{@amount}/u, text) do
      [_, amount] -> to_decimal(amount)
      _ -> nil
    end
  end

  # A price with no unit is per item.
  defp unit(nil), do: "st"
  defp unit(""), do: "st"

  defp unit(word) do
    case String.downcase(word) do
      w when w in ["st", "förp", "fp", "pkt"] -> "st"
      w when w in ["l", "lit", "liter"] -> "l"
      w -> w
    end
  end

  defp to_decimal(amount), do: amount |> String.replace([",", ":"], ".") |> Decimal.new()

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> NaiveDateTime.to_date(ndt)
      _ -> nil
    end
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v), do: v
end
