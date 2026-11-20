defmodule Tore.Deals.PicksTest do
  use Tore.DataCase, async: false

  alias Tore.{Costs, Deals, Recipes, Streams}
  alias Tore.Deals.Picks

  setup do
    store = Repo.insert!(%Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})

    Repo.insert!(%Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })

    {:ok, _} =
      Deals.upsert_deals(
        for name <- ["Laxfilé", "Fläskkarré", "Kattmat"] do
          %{
            chain: "ica",
            store: "ICA Maxi",
            product_name: name,
            price: Decimal.new(49),
            valid_until: Date.add(Tore.Clock.today(), 2)
          }
        end
      )

    {:ok, _} = Recipes.create(home_scope(), %{title: "Laxpasta", base_servings: 4})
    :ok
  end

  defp req, do: Req.new(plug: {Req.Test, __MODULE__})

  # Jev, as the household would have it: salmon yes, pork no, the rest unsure. Each call is told
  # to the test.
  defp jev do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"state" => state, "questions" => questions} = Jason.decode!(body)
      send(test, {:asked, state, Map.keys(questions)})

      answers =
        Map.new(questions, fn {key, %{"instructions" => text}} ->
          chance =
            cond do
              text =~ "Laxfilé" -> 0.9
              text =~ "Fläskkarré" -> 0.1
              true -> 0.3
            end

          {key, %{"noul" => chance}}
        end)

      Req.Test.json(conn, %{"answers" => answers, "usage" => %{"cost" => 0.0001}})
    end)
  end

  defp by_name(chances) do
    names = Map.new(Deals.list_current(home_scope()), &{&1.id, &1.product_name})
    Map.new(chances, fn {id, chance} -> {names[id], chance} end)
  end

  test "Jev guesses which offers the household wants, from what Tore knows of it" do
    jev()

    assert {:ok, 3} = Picks.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, state, [_, _, _]}
    assert Enum.any?(state, &(&1 =~ "Laxpasta"))

    assert by_name(Picks.chances(home_scope())) ==
             %{"Laxfilé" => 0.9, "Fläskkarré" => 0.1, "Kattmat" => 0.3}

    assert Costs.last_llm_call(home_scope(), "deal_picks")
  end

  test "an offer is asked about once" do
    jev()
    {:ok, 3} = Picks.sort(home_scope(), req: req(), api_key: "k")
    assert_received {:asked, _, _}

    assert {:ok, 0} = Picks.sort(home_scope(), req: req(), api_key: "k")
    refute_received {:asked, _, _}
  end

  test "a household without AI isn't asked about" do
    jev()
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Picks.sort(unsponsored, req: req(), api_key: "k")
    refute_received {:asked, _, _}
  end

  test "on Erbjudanden, the offers Jev thinks they want come before the rest, likeliest first" do
    jev()
    {:ok, 3} = Picks.sort(home_scope(), req: req(), api_key: "k")

    today = Tore.Clock.today()
    page = Deals.page(home_scope(), Streams.monday(today), today)

    assert Enum.map(page.picked, & &1.name) == ["Laxfilé"]
    assert Enum.sort(Enum.map(page.others, & &1.name)) == ["Fläskkarré", "Kattmat"]
  end
end
