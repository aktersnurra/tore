defmodule ToreWeb.CostLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Tore.{Costs, Planning}
  alias Tore.Capture.Uploads

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    user = user_fixture(name: "Tester")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> flunk("Timed out waiting for condition")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp this_month(day), do: Date.utc_today() |> Date.beginning_of_month() |> Date.add(day - 1)

  defp last_month(day) do
    start =
      Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

    Date.add(start, day - 1)
  end

  test "shows this month's total against last month", %{conn: conn, user: user} do
    {:ok, _} =
      Costs.log_receipt(home_scope(), %{
        date: this_month(1),
        total_amount: "1500",
        user_id: user.id
      })

    {:ok, _} =
      Costs.log_receipt(home_scope(), %{
        date: last_month(1),
        total_amount: "1000",
        user_id: user.id
      })

    {:ok, lv, html} = live(conn, "/settings/costs")

    assert lv |> element("#month-total") |> render() =~ "1 500 kr"
    assert html =~ "+50%"
  end

  test "survives a run finishing elsewhere while it's open", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/settings/costs")
    run = Tore.RunFixtures.pending_review_fixture(home_scope())

    Phoenix.PubSub.broadcast(
      Tore.PubSub,
      Tore.Harness.Runs.topic(home_scope()),
      {:run_changed, run}
    )

    assert render(lv) =~ "cost-page"
  end

  test "has no tabs, charts or breakdowns", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/settings/costs")

    refute html =~ "cost-tabs"
    refute html =~ "conic-gradient"
    refute html =~ "cost-grocery-art"
  end

  test "a typed total appears in the receipts and the total", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/settings/costs")

    html =
      lv
      |> form("#receipt-form", %{
        date: Date.to_iso8601(Date.utc_today()),
        store_name: "ICA Danvikstull",
        total_amount: "89.50"
      })
      |> render_submit()

    assert html =~ "ICA Danvikstull"
    assert lv |> element("#month-total") |> render() =~ "90 kr"
  end

  test "a typed receipt with no total or a bad date isn't saved", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/settings/costs")

    render_submit(lv, "save_receipt", %{
      "date" => "2026-11-06",
      "store_name" => "",
      "total_amount" => ""
    })

    render_submit(lv, "save_receipt", %{
      "date" => "nope",
      "store_name" => "",
      "total_amount" => "5"
    })

    assert Costs.recent_receipts(home_scope(), 5) == []
  end

  test "lists eating out from the plan, with and without an amount", %{conn: conn} do
    today = Date.utc_today()
    monday = Date.add(today, -(Date.day_of_week(today) - 1))
    plan_id = Tore.Streams.plan(home_scope(), monday)
    days = ~w(mon tue wed thu fri sat sun)
    key = "#{Enum.at(days, Date.day_of_week(today) - 1)}_dinner"

    {:ok, _} =
      Planning.eat_out(home_scope(), plan_id, key, %{place: "Sushi", amount: "450"})

    {:ok, lv, _html} = live(conn, "/settings/costs")
    row = lv |> element("#eating-out") |> render()
    assert row =~ "Sushi"
    assert row =~ "450 kr"

    {:ok, _} =
      Planning.eat_out(home_scope(), plan_id, key, %{place: "", amount: ""})

    {:ok, lv, _html} = live(conn, "/settings/costs")
    row = lv |> element("#eating-out") |> render()
    refute row =~ "Sushi"
    refute row =~ " kr"
  end

  describe "a receipt photo" do
    defp upload(lv) do
      photo =
        file_input(lv, "#receipt-photo-form", :receipt_photo, [
          %{name: "receipt.jpg", content: "receipt-bytes", type: "image/jpeg"}
        ])

      render_upload(photo, "receipt.jpg")
    end

    test "saves a receipt that adds up, and says so", %{conn: conn} do
      expect(Tore.MockLLM, :vision, fn _images, _system, _user, _opts ->
        {:ok,
         %{
           "total" => 89.5,
           "store_name" => "ICA",
           "purchase_date" => "2026-11-05",
           "items" => [
             %{"name" => "Mjölk", "quantity" => 1, "unit" => "st", "category" => "dairy"}
           ]
         }, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
      end)

      {:ok, lv, _html} = live(conn, "/settings/costs")
      upload(lv)

      eventually(fn -> render(lv) =~ "ICA" end)
      assert [%{store_name: "ICA"}] = Costs.recent_receipts(home_scope(), 5)
    end

    test "says so when the photo was already uploaded", %{conn: conn} do
      household_id = home_scope().household_id

      Uploads.record(
        Tore.Scope.for_household(household_id),
        Uploads.content_hash("receipt-bytes"),
        "kr_seen",
        "receipt"
      )

      {:ok, lv, _html} = live(conn, "/settings/costs")
      upload(lv)

      assert_eventually(fn -> render(lv) =~ "redan laddat upp" end)
      assert Costs.recent_receipts(home_scope(), 5) == []
    end

    defp assert_eventually(check, tries \\ 40) do
      cond do
        check.() ->
          :ok

        tries == 0 ->
          flunk("condition never held")

        true ->
          Process.sleep(25)
          assert_eventually(check, tries - 1)
      end
    end
  end
end
