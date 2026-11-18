defmodule ToreWeb.CaptureLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Tore.FakePi

  setup :fake_pi

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp eventually(fun, attempts \\ 80)
  defp eventually(_fun, 0), do: flunk("Timed out waiting for condition")

  defp eventually(fun, attempts) do
    if fun.(), do: true, else: Process.sleep(25) && eventually(fun, attempts - 1)
  end

  defp prompts(log), do: for(%{"type" => "prompt"} = p <- pi_records(log), do: p)

  # A dinner set the way pi sets one, over MCP: the tool's text and its run.
  defp set_dinner do
    {:ok, recipe} =
      Tore.Repo.insert(%Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Pizza",
        recipe_type: :meal
      })

    args = %{"date" => "2026-06-23", "recipe_id" => recipe.id}

    {:reply, %{"result" => %{"content" => [%{"text" => text}], "structuredContent" => result}}} =
      Tore.Mcp.handle(home_scope(), %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "set_dinner", "arguments" => args}
      })

    %{args: args, text: text, done: result.done, run_id: result.run_id}
  end

  defp tuesday_planned? do
    {:ok, plan} =
      Tore.Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), ~D[2026-06-22]))

    Map.has_key?(plan.slots, "tue_dinner")
  end

  test "an empty conversation asks what they need", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/capture")
    assert html =~ "Fråga Tore"
    assert render_async(lv) =~ "Vad behöver du?"
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

  test "a message goes to their own chat with pi, and the answer streams in", %{
    conn: conn,
    user: user,
    pi_log: log
  } do
    {:ok, lv, _html} = live(conn, "/capture")
    html = lv |> form("form", %{message: "Vad ska jag laga?"}) |> render_submit()

    assert html =~ "Vad ska jag laga?"
    assert eventually(fn -> render(lv) =~ "echo: Vad ska jag laga?" end)

    [header | _] = pi_records(log)
    assert header["session"] == "chat-#{user.id}"
    assert [%{"message" => "Vad ska jag laga?"}] = prompts(log)
  end

  test "a change pi makes shows its receipt, and Undo takes it back", %{conn: conn} do
    dinner = set_dinner()

    System.put_env(
      "FAKE_PI_TOOL",
      Jason.encode!(%{name: "mcp__tore__set_dinner", args: dinner.args, result: dinner.text})
    )

    {:ok, lv, _html} = live(conn, "/capture")
    lv |> form("form", %{message: "pizza på tisdag"}) |> render_submit()

    assert eventually(fn -> has_element?(lv, "button", "Ångra") end)
    assert render(lv) =~ dinner.done
    assert tuesday_planned?()

    lv |> element("button", "Ångra") |> render_click()

    refute tuesday_planned?()
    assert render(lv) =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "undone by asking pi, the change's receipt says so", %{conn: conn} do
    dinner = set_dinner()
    undone = Jason.encode!(%{done: "Undone.", run_id: dinner.run_id})

    System.put_env(
      "FAKE_PI_HISTORY",
      Jason.encode!([
        %{
          "role" => "toolResult",
          "toolName" => "mcp__tore__set_dinner",
          "isError" => false,
          "content" => [%{"type" => "text", "text" => dinner.text}]
        }
      ])
    )

    System.put_env(
      "FAKE_PI_TOOL",
      Jason.encode!(%{name: "mcp__tore__undo", args: %{run_id: dinner.run_id}, result: undone})
    )

    {:ok, lv, _html} = live(conn, "/capture")
    render_async(lv)
    assert has_element?(lv, "button", "Ångra")

    # What pi's undo call does in Tore, while the fake answers with its result.
    {:ok, _} = Tore.Harness.Runs.revert(home_scope(), dinner.run_id)
    lv |> form("form", %{message: "ångra pizzan"}) |> render_submit()

    assert eventually(fn -> render(lv) =~ "echo: ångra pizzan" end)
    refute has_element?(lv, "button", "Ångra")
    assert render(lv) =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "the conversation is there when the tray opens, with what has been undone", %{conn: conn} do
    dinner = set_dinner()
    {:ok, _} = Tore.Harness.Runs.revert(home_scope(), dinner.run_id)

    System.put_env(
      "FAKE_PI_HISTORY",
      Jason.encode!([
        %{"role" => "user", "content" => "Pizza på tisdag"},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "toolCall", "id" => "c1", "name" => "mcp__tore__set_dinner"}]
        },
        %{
          "role" => "toolResult",
          "toolName" => "mcp__tore__set_dinner",
          "isError" => false,
          "content" => [%{"type" => "text", "text" => dinner.text}]
        },
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Klart, pizza."}]}
      ])
    )

    {:ok, lv, _html} = live(conn, "/capture")
    html = render_async(lv)

    assert html =~ "Pizza på tisdag"
    assert html =~ dinner.done
    assert html =~ "Klart, pizza."
    refute has_element?(lv, "button", "Ångra")
    assert html =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "a photo goes to pi with what was written", %{conn: conn, pi_log: log} do
    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> file_input("form", :chat_photos, [
      %{name: "kvitto.jpg", content: "jpegbytes", type: "image/jpeg"}
    ])
    |> render_upload("kvitto.jpg")

    lv |> form("form", %{message: ""}) |> render_submit()
    assert eventually(fn -> prompts(log) != [] end)

    [%{"message" => message, "images" => [image]}] = prompts(log)
    assert message == Gettext.dgettext(ToreWeb.Gettext, "default", "1 photo")

    assert image == %{
             "type" => "image",
             "mimeType" => "image/jpeg",
             "data" => Base.encode64("jpegbytes")
           }
  end

  test "without pi, sending says it couldn't", %{conn: conn} do
    Application.delete_env(:tore, :pi)
    {:ok, lv, _html} = live(conn, "/capture")

    html = lv |> form("form", %{message: "hej"}) |> render_submit()
    assert html =~ "Tore kunde inte slutföra det."
  end

  describe "suggestions" do
    alias Tore.Harness.Artifact.HomePick

    defp store_pick(swaps) do
      {:ok, _} =
        Tore.Harness.Runs.submit(
          home_scope(),
          Tore.Harness.Kinds.HomePick,
          %HomePick{screen: :today, source: :model, swaps: swaps},
          %{}
        )
    end

    test "are the stored pick's, and one that opens a screen goes there", %{conn: conn} do
      store_pick([:open_shop])
      {:ok, lv, _html} = live(conn, ~p"/capture")

      assert {:error, {:live_redirect, %{to: "/shop"}}} =
               lv |> element(~s([data-role="swap"]), "Inköpslistan") |> render_click()
    end

    test "one with a request sends it to pi", %{conn: conn, pi_log: log} do
      store_pick([:plan_next_week])
      {:ok, lv, _html} = live(conn, ~p"/capture")

      lv |> element(~s([data-role="swap"]), "Planera nästa vecka") |> render_click()

      assert eventually(fn -> render(lv) =~ "echo: " end)
      assert [%{"message" => message}] = prompts(log)
      assert message =~ "Planera nästa vecka"
    end

    test "a turn's suggestions replace the pick's", %{conn: conn, user: user} do
      store_pick([:open_plan])
      {:ok, lv, _html} = live(conn, ~p"/capture")

      Phoenix.PubSub.broadcast(
        Tore.PubSub,
        Tore.Home.swaps_topic(user.id),
        {:quick_swaps, [%{label: "Mer pasta", action: {:prompt, "Mer pasta"}}]}
      )

      html = render(lv)
      assert html =~ "Mer pasta"
      refute html =~ "Veckans plan"
    end
  end
end
