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

    valid_until = parse_date(offer["validTo"])

    # Build offer price label: prefer mechanicInfo ("3 för 42 kr", "35 kr/st"),
    # fall back to composing from parsed mechanics
    mechanic_label =
      nilify(details["mechanicInfo"]) ||
        nilify(
          "#{mechanics["value1"]} #{mechanics["value2"]} kr#{mechanics["value4"]}"
          |> String.trim()
        )

    # Regular price comes from the store entry, e.g. "52,89-57,83" or "267"
    regular_price = nilify(store["regularPrice"])

    # Comparison price, e.g. "87:50/kg" — normalise colon separator to dot
    comparison_price =
      offer["comparisonPrice"]
      |> nilify()
      |> then(fn
        nil -> nil
        s -> Regex.replace(~r/(\d+):(\d+)/, s, "\\1.\\2")
      end)

    store_name = nilify(store["storeMarketingName"]) || "ICA"

    %{
      chain: "ica",
      store: store_name,
      store_location: store_name,
      product_name: details["name"] || "",
      brand: nilify(details["brand"]),
      size: nilify(details["packageInformation"]),
      price: parse_price(mechanics["value2"]),
      price_unit: nilify(mechanics["value4"]),
      offer_condition: mechanic_label,
      regular_price: regular_price,
      comparison_price: comparison_price,
      valid_until: valid_until,
      source: :scraped
    }
  end

  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil

  defp parse_price(str) do
    case Regex.run(~r/(\d+[,.]?\d*)/, str) do
      [_, digits] -> digits |> String.replace(",", ".") |> Decimal.new()
      _ -> nil
    end
  end

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
