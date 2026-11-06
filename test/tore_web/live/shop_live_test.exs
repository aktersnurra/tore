defmodule ToreWeb.ShopLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: flunk("Timed out waiting for condition")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  describe "grocery item object sheet" do
    test "long-pressing a grocery row opens an item sheet whose input routes a scoped command",
         %{conn: conn} do
      stub(Tore.MockLLM, :text, fn _s, _u, _o -> {:ok, %{"section" => "dairy"}, %{}} end)

      {:ok, view, _} = live(conn, ~p"/shop")

      view
      |> form(~s(form[phx-submit="add_item"]), %{name: "feta", quantity: "", unit: ""})
      |> render_submit()

      item_id = item_id_from_render(view)

      view
      |> element(~s([phx-hook="LongPress"][data-item-name="feta"]))
      |> render_hook("open_item_sheet", %{"item_id" => item_id})

      assert render(view) =~ ~s(phx-submit="item_command")
      assert render(view) =~ "feta"

      expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
        content = msgs |> List.last() |> Map.fetch!(:content)
        assert content =~ "The user is referring to the grocery item"
        assert content =~ "feta"
        assert content =~ "byt till Apetina 200 g"

        {:ok, {:message, "Done."},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end)

      view
      |> form(~s(form[phx-submit="item_command"]), %{command: "byt till Apetina 200 g"})
      |> render_submit()

      refute render(view) =~ ~s(phx-submit="item_command")

      eventually(fn -> render(view) =~ "Done" end)
    end

    test "escape closes the item sheet without routing", %{conn: conn} do
      stub(Tore.MockLLM, :text, fn _s, _u, _o -> {:ok, %{"section" => "dairy"}, %{}} end)

      {:ok, view, _} = live(conn, ~p"/shop")

      view
      |> form(~s(form[phx-submit="add_item"]), %{name: "feta", quantity: "", unit: ""})
      |> render_submit()

      item_id = item_id_from_render(view)

      view
      |> element(~s([phx-hook="LongPress"][data-item-name="feta"]))
      |> render_hook("open_item_sheet", %{"item_id" => item_id})

      assert render(view) =~ ~s(phx-submit="item_command")

      render_hook(view, "close_item_sheet", %{})

      refute render(view) =~ ~s(phx-submit="item_command")
    end
  end

  defp item_id_from_render(view) do
    [_, id] =
      Regex.run(~r/data-item-id="([^"]+)"/, render(view)) ||
        flunk("no grocery row with data-item-id rendered")

    id
  end
end
