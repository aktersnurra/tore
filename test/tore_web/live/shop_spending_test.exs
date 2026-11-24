defmodule ToreWeb.ShopSpendingTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Tore.{Costs, Planning}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    user = user_fixture(name: "Tester")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp this_month(day), do: Tore.Clock.today() |> Date.beginning_of_month() |> Date.add(day - 1)

  defp last_month(day) do
    start =
      Tore.Clock.today() |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

    Date.add(start, day - 1)
  end

  test "shows this month's total against last month, under the list", %{conn: conn, user: user} do
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

    {:ok, lv, html} = live(conn, "/shop")

    assert lv |> element("#month-total") |> render() =~ "1 500 kr"
    assert html =~ "+50%"
  end

  test "lists eating out from the plan, with and without an amount", %{conn: conn} do
    today = Tore.Clock.today()
    monday = Date.add(today, -(Date.day_of_week(today) - 1))
    plan_id = Tore.Streams.plan(home_scope(), monday)
    days = ~w(mon tue wed thu fri sat sun)
    key = "#{Enum.at(days, Date.day_of_week(today) - 1)}_dinner"

    {:ok, _} =
      Planning.eat_out(home_scope(), plan_id, key, %{place: "Sushi", amount: "450"})

    {:ok, lv, _html} = live(conn, "/shop")
    row = lv |> element("#spending") |> render()
    assert row =~ "Sushi"
    assert row =~ "450 kr"

    {:ok, _} =
      Planning.eat_out(home_scope(), plan_id, key, %{place: "", amount: ""})

    {:ok, lv, _html} = live(conn, "/shop")
    row = lv |> element("#spending ul") |> render()
    refute row =~ "Sushi"
    refute row =~ "450 kr"
  end

  describe "a receipt photo" do
    import Tore.FakePi
    setup :fake_pi

    defp upload(lv) do
      photo =
        file_input(lv, "#receipt-photo-form", :receipt_photo, [
          %{name: "receipt.jpg", content: "receipt-bytes", type: "image/jpeg"}
        ])

      render_upload(photo, "receipt.jpg")
    end

    @tag skip: System.find_executable("pdftoppm") == nil && "pdftoppm not installed"
    test "as a PDF goes to pi as pictures of its pages", %{conn: conn, pi_log: log} do
      {:ok, lv, _html} = live(conn, "/shop")

      lv
      |> file_input("#receipt-photo-form", :receipt_photo, [
        %{name: "kvitto.pdf", content: Tore.PdfFixtures.pdf(), type: "application/pdf"}
      ])
      |> render_upload("kvitto.pdf")

      assert_eventually(fn -> Enum.any?(pi_records(log), &(&1["type"] == "prompt")) end)
      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))
      assert [%{"type" => "image", "mimeType" => "image/jpeg"}] = prompt["images"]
    end

    test "goes to pi in the person's chat, and the spending shows what pi logs", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
      hold(log)
      {:ok, lv, _html} = live(conn, "/shop")
      upload(lv)
      assert render(lv) =~ "Läser kvittot"

      assert_eventually(fn ->
        Enum.any?(pi_records(log), &(&1["type"] == "prompt" and &1["message"] =~ "receipt"))
      end)

      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))

      assert [%{"type" => "image", "mimeType" => "image/jpeg", "data" => data}] =
               prompt["images"]

      assert Base.decode64!(data) == "receipt-bytes"

      # pi logs it, as log_receipt does.
      scope = %{home_scope() | user_id: user.id}

      {:reply, %{"result" => %{"isError" => false}}} =
        Tore.Mcp.handle(scope, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "log_receipt",
            "arguments" => %{
              "store" => "ICA",
              "date" => Date.to_iso8601(Tore.Clock.today()),
              "total" => 89.5
            }
          }
        })

      assert_eventually(fn -> lv |> element("#spending") |> render() =~ "ICA" end)
      release(log)
      assert_eventually(fn -> not (render(lv) =~ "Läser kvittot") end)
      assert render(lv) =~ "echo: From the Shop screen"
    end

    defp assert_eventually(check, tries \\ 200) do
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
