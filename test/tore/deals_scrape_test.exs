defmodule Tore.DealsScrapeTest do
  use ExUnit.Case, async: false

  import Mox
  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  @ica_html ~s({"weeklyOffers":[{"details":{"name":"Kycklingfilé","brand":"Kronfågel"},"parsedMechanics":{"value1":"1","value2":"59","value4":"/kg"},"stores":[{"storeMarketingName":"ICA Maxi","regularPrice":"89"}],"comparisonPrice":null,"validTo":null}],"compensationOffersStatus":"ok"})

  @store_url "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  test "scrape_url fetches HTML, parses deals, and upserts under the store's name and chain" do
    Tore.MockHTTP
    |> expect(:fetch, fn @store_url -> {:ok, @ica_html} end)

    assert {:ok, 1} = Tore.Deals.scrape_url(@store_url, "Danvikstull")

    deal = Enum.find(Tore.Deals.list_current(), &(&1.product_name == "Kycklingfilé"))
    assert deal.store == "Danvikstull"
    assert deal.chain == "ica"
  end

  test "scrape_url returns error on HTTP failure" do
    Tore.MockHTTP
    |> expect(:fetch, fn _url -> {:error, :timeout} end)

    assert {:error, :timeout} = Tore.Deals.scrape_url(@store_url, "Danvikstull")
  end

  test "scrape_url never fetches a link no backend handles" do
    # No MockHTTP expectation: any fetch here fails the test.
    assert {:error, :unsupported_store} =
             Tore.Deals.scrape_url("https://evil.example/erbjudanden/", "Evil")
  end

  test "scrape_all returns :ok with no enabled store configs" do
    assert :ok = Tore.Deals.scrape_all()
  end

  describe "stores" do
    test "add_store takes only a link and starts switched on" do
      assert {:ok, store} = Tore.Deals.add_store("  #{@store_url}\n")

      assert store.url == @store_url
      assert store.name == "ICA Supermarket Danvikstull"
      assert store.scrape_enabled
    end

    test "add_store refuses links no backend can read" do
      assert {:error, :unsupported_store} = Tore.Deals.add_store("https://www.coop.se/x/")
      assert {:error, :unsupported_store} = Tore.Deals.add_store("http://www.ica.se/x/")
      assert {:error, :unsupported_store} = Tore.Deals.add_store("https://www.ica.se/recept/")
      assert Tore.Deals.list_store_configs() == []
    end

    test "add_store refuses the same link twice" do
      assert {:ok, _} = Tore.Deals.add_store(@store_url)
      assert {:error, %Ecto.Changeset{}} = Tore.Deals.add_store(@store_url)
    end

    test "scrape_all skips stores switched off" do
      {:ok, store} = Tore.Deals.add_store(@store_url)
      {:ok, _} = Tore.Deals.update_store_config(store, %{scrape_enabled: false})

      # No MockHTTP expectation: fetching a switched-off store fails the test.
      assert :ok = Tore.Deals.scrape_all()
    end

    test "scrape_all fetches stores switched on" do
      {:ok, _} = Tore.Deals.add_store(@store_url)

      Tore.MockHTTP
      |> expect(:fetch, fn @store_url -> {:ok, @ica_html} end)

      assert :ok = Tore.Deals.scrape_all()
      assert Enum.any?(Tore.Deals.list_current(), &(&1.store == "ICA Supermarket Danvikstull"))
    end
  end

  test "no scheduled job generates prep guides" do
    jobs = Application.fetch_env!(:tore, Tore.Scheduler)[:jobs]

    assert Enum.any?(jobs, &match?({_, {Tore.Deals, :scrape_all, []}}, &1))
    refute Enum.any?(jobs, &match?({_, {Tore.Prep, _, _}}, &1))
    # A job given as a closure can't be inspected, which is how this one hid.
    assert Enum.all?(jobs, &match?({_, {_, _, _}}, &1))
  end
end
