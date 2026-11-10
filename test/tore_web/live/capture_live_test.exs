defmodule ToreWeb.CaptureLiveTest do
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

  test "mount renders empty chat", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/capture")
    assert html =~ "Fråga Tore"
  end

  test "capture renders as a sheet with a close affordance", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/capture")
    assert html =~ ~s(data-role="command-tray")
    assert html =~ ~s(data-role="tray-close")
  end

  test "return_to only accepts internal paths", %{conn: conn} do
    for evil <- ["https://evil.example", "//evil.example", "/\\evil.example"] do
      {:ok, _view, html} = live(conn, ~p"/capture?return_to=#{evil}")
      refute html =~ "evil.example"
    end

    {:ok, view, _html} = live(conn, ~p"/capture?return_to=/plan")

    assert view
           |> element(~s([data-role="tray-close"]))
           |> render() =~ ~s(href="/plan")
  end

  test "sending a message appends user bubble", %{conn: conn} do
    Tore.MockLLM
    |> expect(:chat_with_tools, fn _system, _messages, _tools, _opts ->
      {:ok, {:message, "Try making pasta tonight!"},
       %{prompt_tokens: 10, completion_tokens: 8, cost_usd: 0.0001}}
    end)

    {:ok, lv, _html} = live(conn, "/capture")

    html =
      lv
      |> form("form", %{message: "What should I cook?"})
      |> render_submit()

    assert html =~ "What should I cook?"

    :timer.sleep(200)
    html = render(lv)
    assert html =~ "Try making pasta tonight!"
  end

  test "Undo on a set_plan_slot bubble reverts the run and marks the bubble", %{conn: conn} do
    {:ok, recipe} =
      %Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Pizza",
        recipe_type: :meal
      }
      |> Tore.Repo.insert()

    tool_call = %{
      id: "call_1",
      name: "set_plan_slot",
      args: %{"date" => "2026-06-23", "recipe_id" => recipe.id, "servings" => 4}
    }

    Tore.MockLLM
    |> expect(:chat_with_tools, 2, fn _sys, _msgs, _tools, _opts ->
      case Process.get(:turn_count, 0) do
        0 ->
          Process.put(:turn_count, 1)

          {:ok, {:tool_calls, [tool_call]},
           %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}

        _ ->
          {:ok, {:message, "Done."},
           %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end
    end)

    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> form("form", %{message: "plan pizza tuesday"})
    |> render_submit()

    :timer.sleep(300)
    html = render(lv)
    assert html =~ "Pizza"
    assert html =~ "Ångra"

    {:ok, plan_state} =
      Tore.Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), ~D[2026-06-22]))

    assert Map.has_key?(plan_state.slots, "tue_dinner")

    lv |> element("button", "Ångra") |> render_click()

    {:ok, plan_state2} =
      Tore.Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), ~D[2026-06-22]))

    refute Map.has_key?(plan_state2.slots, "tue_dinner")

    html2 = render(lv)
    assert html2 =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "a shelf photo replies in the user's language and can be undone", %{conn: conn} do
    usage = %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}
    tool_call = %{id: "call_1", name: "update_pantry_from_shelf", args: %{"image_indices" => [1]}}

    Tore.MockLLM
    |> expect(:chat_with_tools, 2, fn _sys, _msgs, _tools, _opts ->
      case Process.get(:turn_count, 0) do
        0 ->
          Process.put(:turn_count, 1)
          {:ok, {:tool_calls, [tool_call]}, usage}

        _ ->
          {:ok, {:message, "Klart."}, usage}
      end
    end)
    |> expect(:vision, fn _blobs, _sys, _user, _opts ->
      {:ok,
       %{
         "items" => [%{"name" => "mjölk", "quantity" => 2, "unit" => "l", "category" => "dairy"}]
       }, usage}
    end)
    |> expect(:text, fn _sys, _user, _opts ->
      {:ok,
       %{
         "items" => [
           %{
             "raw_name" => "mjölk",
             "catalogue_name" => "mjölk",
             "category" => "dairy",
             "default_unit" => "l",
             "matched_key" => nil
           }
         ]
       }, usage}
    end)

    {:ok, lv, _html} = live(conn, "/capture")

    photo =
      file_input(lv, "form", :chat_photos, [
        %{name: "shelf.jpg", content: <<255, 216, 255, 1>>, type: "image/jpeg"}
      ])

    render_upload(photo, "shelf.jpg")
    lv |> form("form", %{message: "hyllan"}) |> render_submit()

    :timer.sleep(300)
    assert render(lv) =~ "La till mjölk från din bild."
    assert [%{name: "mjölk"}] = Tore.Pantry.list_inventory(home_scope())

    lv |> element("button", "Ångra") |> render_click()

    assert Tore.Pantry.list_inventory(home_scope()) == []
    assert render(lv) =~ "Återställd"
  end
end
