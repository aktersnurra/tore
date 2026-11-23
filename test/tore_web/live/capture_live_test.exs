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

  # A chat they've talked in before, so the tray opens on it.
  defp chat_for(user, title \\ nil) do
    scope = scope_fixture(user)
    {:ok, chat} = Tore.Chats.create(scope)
    if title, do: {:ok, _} = Tore.Chats.rename(scope, chat, title)
    Tore.Chats.get(scope, chat.id)
  end

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

  test "a first message starts a chat of its own with pi, and the answer streams in", %{
    conn: conn,
    user: user,
    pi_log: log
  } do
    {:ok, lv, _html} = live(conn, "/capture")
    assert Tore.Chats.list(scope_fixture(user)) == []
    html = lv |> form("#chat-form", %{message: "Vad ska jag laga?"}) |> render_submit()

    assert html =~ "Vad ska jag laga?"
    assert eventually(fn -> render(lv) =~ "echo: Vad ska jag laga?" end)

    [chat] = Tore.Chats.list(scope_fixture(user))
    [header | _] = pi_records(log)
    assert header["session"] == "chat-#{user.id}-#{chat.id}"

    # pi is asked to name the chat while it has no title; the bubble keeps their words.
    assert [%{"message" => "Vad ska jag laga?" <> note}] = prompts(log)
    assert note =~ "describe_chat"
    # Their question is answered first; the card is done quietly, not talked about.
    assert note =~ "Answer them as you would anyway"
    assert note =~ "without mentioning it"
    refute has_element?(lv, ~s([data-role="bubble-user"]), "describe_chat")
  end

  test "a chat with a title is sent their words as they are", %{
    conn: conn,
    user: user,
    pi_log: log
  } do
    chat_for(user, "Helgen")
    {:ok, lv, _html} = live(conn, "/capture")
    lv |> form("#chat-form", %{message: "Och söndag?"}) |> render_submit()

    assert eventually(fn -> prompts(log) != [] end)
    assert [%{"message" => "Och söndag?"}] = prompts(log)
  end

  describe "chats" do
    test "the tray opens on the chat used last, with its title, which can be changed", %{
      conn: conn,
      user: user
    } do
      _older = chat_for(user, "Lax")
      latest = chat_for(user, "Helgen")

      {:ok, lv, _html} = live(conn, "/capture")
      assert has_element?(lv, ~s(input[name="title"][value="Helgen"]))

      lv |> form(~s([data-role="chat-title"]), %{title: "Middag i helgen"}) |> render_submit()
      assert Tore.Chats.get(scope_fixture(user), latest.id).title == "Middag i helgen"
    end

    test "a chat last used yesterday isn't reopened: the tray starts a new one", %{
      conn: conn,
      user: user
    } do
      chat_for(user, "Igår")
      yesterday = DateTime.add(DateTime.utc_now(), -1, :day)

      Tore.Repo.update_all(
        Tore.Chats.Chat,
        [set: [updated_at: yesterday]],
        Tore.Scope.repo_opts(scope_fixture(user))
      )

      {:ok, lv, _html} = live(conn, "/capture")
      refute has_element?(lv, ~s(input[name="title"][value="Igår"]))
      assert has_element?(lv, "header span", "Ny chatt")

      # It's still in the list.
      lv |> element(~s(button[data-role="chats"])) |> render_click()
      assert has_element?(lv, ~s([data-role="chat-list"]), "Igår")
    end

    test "a new chat starts from the button beside the close", %{conn: conn, user: user} do
      chat_for(user, "Helgen")
      {:ok, lv, _html} = live(conn, "/capture?return_to=/plan")

      lv |> element(~s(header button[data-role="tray-new-chat"])) |> render_click()
      assert_patch(lv, "/capture?new=true&return_to=%2Fplan")
      refute has_element?(lv, ~s(input[name="title"][value]))
      # Already a new chat: nothing to start again.
      refute has_element?(lv, ~s(header button[data-role="tray-new-chat"]))
    end

    test "a title pi gives shows at once", %{conn: conn, user: user} do
      chat = chat_for(user)
      {:ok, lv, _html} = live(conn, "/capture")

      {:ok, _} = Tore.Chats.rename(scope_fixture(user), chat, "Tacos på fredag")
      assert has_element?(lv, ~s(input[name="title"][value="Tacos på fredag"]))
    end

    test "the list has their chats, opens one, and starts a new one", %{conn: conn, user: user} do
      lax = chat_for(user, "Lax")
      _helgen = chat_for(user, "Helgen")

      {:ok, lv, _html} = live(conn, "/capture?return_to=/plan")
      lv |> element(~s(button[data-role="chats"])) |> render_click()
      assert has_element?(lv, ~s([data-role="chat-list"]), "Lax")
      assert has_element?(lv, ~s([data-role="chat-list"]), "Helgen")

      lv |> element(~s([data-role="chat-list"] button), "Lax") |> render_click()
      assert_patch(lv, "/capture?chat=#{lax.id}&return_to=%2Fplan")

      lv |> element(~s(button[data-role="chats"])) |> render_click()
      lv |> element(~s([data-role="new-chat"])) |> render_click()
      assert_patch(lv, "/capture?new=true&return_to=%2Fplan")
      refute has_element?(lv, ~s(input[name="title"][value]))
    end

    test "the list can be searched by the chats' cards", %{conn: conn, user: user} do
      scope = scope_fixture(user)
      {:ok, lax} = Tore.Chats.create(scope)
      {:ok, _} = Tore.Chats.describe(scope, lax, %{"title" => "Lax", "summary" => "Laxpasta."})
      chat_for(user, "Budgeten")

      {:ok, lv, _html} = live(conn, "/capture")
      lv |> element(~s(button[data-role="chats"])) |> render_click()
      lv |> form(~s([data-role="chat-search"]), %{q: "laxpasta"}) |> render_change()

      assert has_element?(lv, ~s([data-role="chat-list"] button), "Lax")
      refute has_element?(lv, ~s([data-role="chat-list"] button), "Budgeten")
    end

    test "when pi opens an earlier chat, the tray goes there", %{conn: conn, user: user} do
      lookup = chat_for(user)
      earlier = chat_for(user, "Lax")

      {:ok, lv, _html} =
        live(conn, "/capture?#{URI.encode_query(chat: lookup.id, return_to: "/plan")}")

      :ok = Tore.Chats.open(scope_fixture(user), Tore.Chats.session(lookup), earlier.id)

      assert_patch(lv, "/capture?chat=#{earlier.id}&return_to=%2Fplan")
      assert has_element?(lv, ~s([data-role="chat-title"] input[value="Lax"]))
    end

    test "a new chat or another one opens in place, not as a new page", %{conn: conn, user: user} do
      chat = chat_for(user, "Lax")

      {:ok, lv, _html} =
        live(conn, "/capture?#{URI.encode_query(chat: chat.id, return_to: "/plan")}")

      lv |> element(~s(button[data-role="chats"])) |> render_click()
      lv |> element(~s([data-role="new-chat"])) |> render_click()
      assert_patch(lv, "/capture?new=true&return_to=%2Fplan")
      refute has_element?(lv, ~s([data-role="chat-title"] input[value="Lax"]))

      lv |> element(~s(button[data-role="chats"])) |> render_click()

      lv
      |> element(~s([data-role="chat-list"] button[phx-value-id="#{chat.id}"]))
      |> render_click()

      assert_patch(lv, "/capture?chat=#{chat.id}&return_to=%2Fplan")
      assert has_element?(lv, ~s([data-role="chat-title"] input[value="Lax"]))
    end

    test "pi's suggestions for what to say next show after its answer, and send when tapped", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
      {:ok, lv, _html} = live(conn, "/capture")
      lv |> form("#chat-form", %{message: "Laxpasta?"}) |> render_submit()
      assert eventually(fn -> render(lv) =~ "echo: Laxpasta?" end)

      assert eventually(fn -> not has_element?(lv, ~s([data-role="stop"])) end)

      [chat] = Tore.Chats.list(scope_fixture(user))
      session = Tore.Chats.session(chat)
      replies = ["Gör den vegetarisk", "Lägg den på fredag"]
      send(lv.pid, {:pi, session, %{"type" => "tore_suggestions", "replies" => replies}})

      assert has_element?(lv, ~s([data-role="reply"]), "Gör den vegetarisk")
      refute has_element?(lv, ~s([data-role="swap"]))

      lv |> element(~s([data-role="reply"]), "Gör den vegetarisk") |> render_click()
      assert eventually(fn -> length(prompts(log)) == 2 end)
      # Still untitled (the fake pi doesn't name chats), so pi is asked again.
      assert String.starts_with?(List.last(prompts(log))["message"], "Gör den vegetarisk")
      refute has_element?(lv, ~s([data-role="reply"]))
    end
  end

  describe "recipes in the chat" do
    defp pizza do
      Tore.Repo.insert!(%Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Pizza",
        recipe_type: :meal,
        cook_time_minutes: 25
      })
    end

    # What pi's get_recipe call reads, as Tore's MCP answers it.
    defp read(recipe) do
      {:reply, %{"result" => %{"content" => [%{"text" => text}]}}} =
        Tore.Mcp.handle(home_scope(), %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "get_recipe", "arguments" => %{"recipe_id" => recipe.id}}
        })

      text
    end

    defp card(recipe), do: ~s([data-role="recipe-card"] a[href="/recipes?id=#{recipe.id}"])

    test "a recipe Tore reads shows as its card", %{conn: conn} do
      recipe = pizza()
      text = read(recipe)

      System.put_env(
        "FAKE_PI_TOOL",
        Jason.encode!(%{
          name: "mcp__tore__get_recipe",
          args: %{recipe_id: recipe.id},
          result: text
        })
      )

      {:ok, lv, _html} = live(conn, "/capture")
      lv |> form("#chat-form", %{message: "hur länge tar pizzan?"}) |> render_submit()

      assert eventually(fn -> has_element?(lv, card(recipe)) end)
      assert lv |> element(card(recipe)) |> render() =~ "Pizza"
    end

    test "a card read before shows when the chat opens again, once however often it was read", %{
      conn: conn,
      user: user
    } do
      chat_for(user)
      recipe = pizza()

      read_it = %{
        "role" => "toolResult",
        "toolName" => "mcp__tore__get_recipe",
        "isError" => false,
        "content" => [%{"type" => "text", "text" => read(recipe)}]
      }

      System.put_env("FAKE_PI_HISTORY", Jason.encode!([read_it, read_it]))

      {:ok, lv, _html} = live(conn, "/capture")
      html = render_async(lv)
      assert [_one] = html |> Floki.parse_document!() |> Floki.find(card(recipe))
    end

    test "a recipe's own chat has the recipe on top, and their words as they said them", %{
      conn: conn
    } do
      recipe = pizza()

      System.put_env(
        "FAKE_PI_HISTORY",
        Jason.encode!([
          %{
            "role" => "user",
            "content" => "From the recipe page, about Pizza (recipe #{recipe.id}): till sex?"
          }
        ])
      )

      {:ok, lv, _html} = live(conn, "/capture?recipe=#{recipe.id}")
      html = render_async(lv)

      assert has_element?(lv, card(recipe))
      assert lv |> element(~s([data-role="bubble-user"])) |> render() =~ "till sex?"
      refute html =~ "From the recipe page"
    end
  end

  test "a change pi makes shows its receipt, and Undo takes it back", %{conn: conn} do
    dinner = set_dinner()

    System.put_env(
      "FAKE_PI_TOOL",
      Jason.encode!(%{name: "mcp__tore__set_dinner", args: dinner.args, result: dinner.text})
    )

    {:ok, lv, _html} = live(conn, "/capture")
    lv |> form("#chat-form", %{message: "pizza på tisdag"}) |> render_submit()

    assert eventually(fn -> has_element?(lv, "button", "Ångra") end)
    assert render(lv) =~ dinner.done
    assert tuesday_planned?()

    lv |> element("button", "Ångra") |> render_click()

    refute tuesday_planned?()
    assert render(lv) =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  describe "Undo that can't go through" do
    # A receipt in the conversation, its change made through Tore as pi would make it.
    setup %{user: user} do
      chat_for(user)
      dinner = set_dinner()

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

      %{dinner: dinner}
    end

    test "already undone elsewhere, it says so", %{conn: conn, dinner: dinner} do
      {:ok, lv, _html} = live(conn, "/capture")
      render_async(lv)
      {:ok, _} = Tore.Harness.Runs.revert(home_scope(), dinner.run_id)

      lv |> element("button", "Ångra") |> render_click()

      refute has_element?(lv, "button", "Ångra")
      assert render(lv) =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
    end

    test "a change that's gone, it says why instead of doing nothing", %{
      conn: conn,
      dinner: dinner
    } do
      {:ok, lv, _html} = live(conn, "/capture")
      render_async(lv)

      run = Tore.Harness.Runs.get(home_scope(), dinner.run_id)
      Tore.Repo.delete!(run, Tore.Scope.repo_opts(home_scope()))

      html = lv |> element("button", "Ångra") |> render_click()

      assert html =~ "Den ändringen finns inte längre"
      assert has_element?(lv, "button", "Ångra")
    end
  end

  test "undone by asking pi, the change's receipt says so", %{conn: conn, user: user} do
    chat_for(user)
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
    lv |> form("#chat-form", %{message: "ångra pizzan"}) |> render_submit()

    assert eventually(fn -> render(lv) =~ "echo: ångra pizzan" end)
    refute has_element?(lv, "button", "Ångra")
    assert render(lv) =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "the conversation is there when the tray opens, with what has been undone", %{
    conn: conn,
    user: user
  } do
    chat_for(user)
    dinner = set_dinner()
    {:ok, _} = Tore.Harness.Runs.revert(home_scope(), dinner.run_id)

    System.put_env(
      "FAKE_PI_HISTORY",
      Jason.encode!([
        %{
          "role" => "user",
          "content" =>
            "Pizza på tisdag\n\n(This chat has no title yet: once you've answered, give it its card with describe_chat.)"
        },
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
    refute html =~ "describe_chat"
    assert html =~ dinner.done
    assert html =~ "Klart, pizza."
    refute has_element?(lv, "button", "Ångra")
    assert html =~ Gettext.dgettext(ToreWeb.Gettext, "default", "Reverted")
  end

  test "the chat keeps the app's menu beside it", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/capture")
    assert html =~ ~s(id="tab-bar-live")
  end

  test "while pi works, send becomes stop, which aborts it and leaves its late answer out", %{
    conn: conn,
    pi_log: log
  } do
    hold(log)
    {:ok, lv, _html} = live(conn, "/capture")
    refute has_element?(lv, ~s([data-role="stop"]))

    lv |> form("#chat-form", %{message: "Planera veckan"}) |> render_submit()
    assert has_element?(lv, ~s([data-role="stop"]))
    refute has_element?(lv, ~s(button[type="submit"]))

    lv |> element(~s([data-role="stop"])) |> render_click()
    refute has_element?(lv, ~s([data-role="stop"]))
    assert has_element?(lv, ~s(button[type="submit"]))

    release(log)
    assert eventually(fn -> Enum.any?(pi_records(log), &(&1["type"] == "abort")) end)
    Process.sleep(100)
    refute render(lv) =~ "echo: Planera veckan"
  end

  test "pi's answer is set as markdown, without any HTML it wrote", %{conn: conn, user: user} do
    chat_for(user)

    System.put_env(
      "FAKE_PI_HISTORY",
      Jason.encode!([
        %{"role" => "user", "content" => "Vad behöver jag?"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "**Lax** och:\n\n- dill\n- <script>alert(1)</script>"}
          ]
        }
      ])
    )

    {:ok, lv, _html} = live(conn, "/capture")
    html = render_async(lv)

    assert html =~ "<strong>Lax</strong>"
    assert html =~ "<li>dill</li>"
    refute html =~ "<script>alert"
  end

  test "a photo goes to pi with what was written", %{conn: conn, pi_log: log} do
    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> file_input("#chat-form", :chat_photos, [
      %{name: "kvitto.jpg", content: "jpegbytes", type: "image/jpeg"}
    ])
    |> render_upload("kvitto.jpg")

    lv |> form("#chat-form", %{message: ""}) |> render_submit()
    assert eventually(fn -> prompts(log) != [] end)

    [%{"message" => message, "images" => [image]}] = prompts(log)
    assert String.starts_with?(message, Gettext.dgettext(ToreWeb.Gettext, "default", "1 photo"))

    assert image == %{
             "type" => "image",
             "mimeType" => "image/jpeg",
             "data" => Base.encode64("jpegbytes")
           }
  end

  # On a phone the box is emptied as the message is sent, and LiveView reads the form only once
  # the photo is up: what was written comes in `sent` (the Composer hook).
  test "what was written with a photo is kept while the photo uploads", %{conn: conn, pi_log: log} do
    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> file_input("#chat-form", :chat_photos, [
      %{name: "kyl.jpg", content: "jpegbytes", type: "image/jpeg"}
    ])
    |> render_upload("kyl.jpg")

    html = render_submit(lv, "send_message", %{"message" => "", "sent" => "Vad kan jag laga?"})
    assert html =~ "Vad kan jag laga?"

    assert eventually(fn -> prompts(log) != [] end)
    [%{"message" => message, "images" => [_image]}] = prompts(log)
    assert String.starts_with?(message, "Vad kan jag laga?")
  end

  # A phone back from the background mounts the chat again, at the address it has.
  test "a new chat has its own address once something is sent in it", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/capture?new=true&return_to=/plan")

    lv |> form("#chat-form", %{message: "Hej"}) |> render_submit()
    [chat] = Tore.Chats.list(scope_fixture(user))
    assert_patch(lv, "/capture?chat=#{chat.id}&return_to=%2Fplan")

    # The same conversation: what was sent is still there, and so is the answer.
    assert has_element?(lv, ~s([data-role="bubble-user"]), "Hej")
    assert eventually(fn -> render(lv) =~ "echo: Hej" end)
  end

  test "opened while Tore answers, the chat waits for the rest of the answer", %{
    conn: conn,
    pi_log: log
  } do
    hold(log)
    {:ok, first, _html} = live(conn, "/capture")
    first |> form("#chat-form", %{message: "Planera veckan"}) |> render_submit()

    # The screen they come back to: mounted again, mid-answer.
    {:ok, lv, _html} = live(conn, "/capture")
    render_async(lv)
    assert has_element?(lv, ~s([data-role="bubble-user"]), "Planera veckan")
    assert has_element?(lv, ~s([data-role="stop"]))

    release(log)
    assert eventually(fn -> render(lv) =~ "echo: Planera veckan" end)
    assert eventually(fn -> not has_element?(lv, ~s([data-role="stop"])) end)
  end

  @tag skip: System.find_executable("pdftoppm") == nil && "pdftoppm not installed"
  test "a PDF goes to pi as pictures of its pages", %{conn: conn, pi_log: log} do
    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> file_input("#chat-form", :chat_photos, [
      %{name: "kvitto.pdf", content: Tore.PdfFixtures.pdf(2), type: "application/pdf"}
    ])
    |> render_upload("kvitto.pdf")

    html = lv |> form("#chat-form", %{message: "Logga kvittot"}) |> render_submit()
    assert html =~ "Logga kvittot (1 fil)"
    assert eventually(fn -> prompts(log) != [] end)

    [%{"message" => message, "images" => [first, second]}] = prompts(log)
    assert String.starts_with?(message, "Logga kvittot")

    # Opened again, the history names it the same way, though pi has it as two pictures.
    {:ok, again, _html} = live(conn, "/capture")
    html = render_async(again)
    assert html =~ "Logga kvittot (1 fil)"
    refute has_element?(again, ~s([data-role="bubble-user"]), "Attached:")
    assert %{"type" => "image", "mimeType" => "image/jpeg"} = first
    assert <<0xFF, 0xD8, _::binary>> = Base.decode64!(second["data"])
  end

  test "a PDF that can't be opened says so, and pi isn't asked", %{conn: conn, pi_log: log} do
    {:ok, lv, _html} = live(conn, "/capture")

    lv
    |> file_input("#chat-form", :chat_photos, [
      %{name: "kvitto.pdf", content: "%PDF-1.4 trasig", type: "application/pdf"}
    ])
    |> render_upload("kvitto.pdf")

    html = lv |> form("#chat-form", %{message: "Logga kvittot"}) |> render_submit()
    assert html =~ "Logga kvittot"
    assert has_element?(lv, ~s([data-role="bubble-assistant"]), "PDF")
    assert prompts(log) == []
  end

  test "without pi, sending says it couldn't", %{conn: conn} do
    Application.delete_env(:tore, :pi)
    {:ok, lv, _html} = live(conn, "/capture")

    html = lv |> form("#chat-form", %{message: "hej"}) |> render_submit()
    assert html =~ "Tore kunde inte slutföra det."
  end

  describe "a recipe's own conversation" do
    defp recipe(scope, title) do
      {:ok, recipe} =
        Tore.Repo.insert(%Tore.Recipes.Recipe{
          household_id: scope.household_id,
          title: title,
          recipe_type: :meal
        })

      recipe
    end

    test "Ask Tore on a recipe talks in that recipe's session, and says once what it's about", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
      salmon = recipe(home_scope(), "Laxpasta")
      {:ok, lv, html} = live(conn, ~p"/capture?#{[recipe: salmon.id]}")
      assert html =~ "Om Laxpasta"

      lv |> form("#chat-form", %{message: "Gör den vegetarisk"}) |> render_submit()
      assert eventually(fn -> render(lv) =~ "echo: " end)

      [header | _] = pi_records(log)
      assert header["session"] == "chat-#{user.id}-recipe-#{salmon.id}"
      [%{"message" => first}] = prompts(log)
      assert first =~ "Laxpasta (recipe #{salmon.id})"
      assert first =~ "Gör den vegetarisk"

      lv |> form("#chat-form", %{message: "Och för sex"}) |> render_submit()
      assert eventually(fn -> length(prompts(log)) == 2 end)
      assert List.last(prompts(log))["message"] == "Och för sex"
    end

    test "the quick swaps stay with the kitchen's chat", %{conn: conn} do
      {:ok, _} =
        Tore.Harness.Runs.submit(
          home_scope(),
          Tore.Harness.Kinds.HomePick,
          %Tore.Harness.Artifact.HomePick{screen: :today, source: :model, swaps: [:open_shop]},
          %{}
        )

      {:ok, lv, _html} = live(conn, ~p"/capture?#{[recipe: recipe(home_scope(), "Laxpasta").id]}")
      refute has_element?(lv, ~s([data-role="swap"]))
    end

    test "a recipe that isn't the household's opens their own chat", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
      theirs = recipe(scope_fixture(household_fixture()), "Hemlig gryta")
      {:ok, lv, html} = live(conn, ~p"/capture?#{[recipe: theirs.id]}")
      refute html =~ "Hemlig gryta"

      lv |> form("#chat-form", %{message: "hej"}) |> render_submit()
      assert eventually(fn -> prompts(log) != [] end)
      [chat] = Tore.Chats.list(scope_fixture(user))
      assert hd(pi_records(log))["session"] == Tore.Chats.session(chat)
      assert [%{"message" => "hej" <> _card_note}] = prompts(log)
    end
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
  end
end
