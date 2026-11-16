defmodule Tore.Deals.Parsers.ICATest do
  use ExUnit.Case, async: true

  alias Tore.Deals.Deal
  alias Tore.Deals.Parsers.ICA

  # Shapes seen on ICA Supermarket Danvikstull's page on 2026-11-04.
  defp offer(name, mechanic, regular, comparison, opts \\ []) do
    %{
      "details" => %{
        "name" => name,
        "brand" => opts[:brand],
        "packageInformation" => opts[:size],
        "mechanicInfo" => mechanic
      },
      "parsedMechanics" => opts[:mechanics] || %{},
      "stores" => [%{"storeMarketingName" => "ICA Maxi", "regularPrice" => regular}],
      "comparisonPrice" => comparison,
      "validTo" => Keyword.get(opts, :valid_to, "2026-11-08T00:00:00")
    }
  end

  defp parse_one(offer) do
    html = ~s({"weeklyOffers":#{Jason.encode!([offer])},"compensationOffersStatus":"ok"})
    assert {:ok, [deal]} = ICA.parse(html)
    deal
  end

  test "keeps the öre of a price" do
    deal = parse_one(offer("Mozzarella 21% Riv", "39,90 kr/st", "63,50", "79:80/kg"))

    assert deal.price == Decimal.new("39.90")
    assert deal.quantity == 1
    assert deal.price_unit == "st"
    assert deal.regular_price == Decimal.new("63.50")
  end

  test "a multi-buy is a price for several items" do
    deal = parse_one(offer("Gräddglass, Sorbet", "3 för 40 kr", "19,90-21,90", "26:67/liter"))

    assert deal.price == Decimal.new("40")
    assert deal.quantity == 3
    assert deal.price_unit == "st"
    assert Deal.unit_price(struct(Deal, deal)) == Decimal.new("13.33")
    assert deal.regular_price == Decimal.new("19.90")
  end

  test "a multi-buy that counts in st" do
    assert %{price: price, quantity: 2} =
             parse_one(offer("Yoghurt", "2 st för 30 kr", "17,50", nil))

    assert price == Decimal.new("30")
  end

  test "a price per kilo" do
    deal = parse_one(offer("Familjefavoriter", "79 kr/kg", "102,50-121,50", nil))

    assert deal.price == Decimal.new("79")
    assert deal.price_unit == "kg"
    assert deal.comparison_price == nil
    assert deal.comparison_unit == nil
  end

  test "the comparison price as an amount and a unit" do
    assert %{comparison_price: price, comparison_unit: "kg"} =
             parse_one(offer("Stora blåbär i ask", "35 kr/st", "52,90", "155:56/kg"))

    assert price == Decimal.new("155.56")

    assert %{comparison_unit: "l"} =
             parse_one(offer("Vispgrädde", "25 kr/st", "32,30-34,90", "50:00/liter"))

    assert %{comparison_price: low, comparison_unit: "kg"} =
             parse_one(offer("Kräftstjärtar", "99 kr/st", "129", "412:50-495:00/kg u. spad"))

    assert low == Decimal.new("412.50")
  end

  test "an offer that isn't a price has none" do
    assert %{price: nil} = parse_one(offer("Kaffe", "Köp 3 betala för 2", "59,90", nil))
    assert %{price: nil} = parse_one(offer("Ost", "Spara 10 kr", "89", nil))
    assert %{price: nil} = parse_one(offer("Glass", "20% rabatt", "45", nil))
  end

  test "without mechanicInfo the parsed mechanics give the price" do
    deal =
      parse_one(
        offer("Kycklingfilé", nil, "89", nil,
          mechanics: %{"value1" => "1", "value2" => "59", "value4" => "/kg"}
        )
      )

    assert deal.price == Decimal.new("59")
    assert deal.price_unit == "kg"
    assert deal.offer_condition == "1 59 kr/kg"
  end

  test "names, store and end date" do
    deal =
      parse_one(offer("Kycklingfilé", "59 kr/st", "89", nil, brand: "Kronfågel", size: "500g"))

    assert deal.product_name == "Kycklingfilé"
    assert deal.brand == "Kronfågel"
    assert deal.size == "500g"
    assert deal.store == "ICA Maxi"
    assert deal.source == :scraped
    assert deal.valid_until == ~D[2026-11-08]
    assert deal.offer_condition == "59 kr/st"
  end

  test "parse/1 returns error when no embedded data present" do
    assert {:error, :no_initial_data} = ICA.parse("<html><body>No offers</body></html>")
  end
end
