defmodule ToreWeb.HomeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  import Tore.RunFixtures

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"prompt" => "A plate of food."}, %{}}
    end)

    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp today_slot_key do
    days = ~w[mon tue wed thu fri sat sun]
    today = Date.utc_today()
    dow = Date.day_of_week(today)
    day = Enum.at(days, dow - 1)
    "#{day}_dinner"
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

  test "mounts without crash and shows tonight section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Ikväll"
  end

  test "shows nothing planned when no recipe assigned", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Inget planerat ikväll"
  end

  test "today does not render the week strip", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ "Föregående vecka"
  end

  test "renders the command pill linking to capture", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    bottom_nav_html = view |> element(~s(nav[data-role="bottom-nav"])) |> render()
    assert bottom_nav_html =~ ~s(data-role="command-pill")
    assert bottom_nav_html =~ "/capture"
    assert bottom_nav_html =~ "return_to=%2F"
    refute bottom_nav_html =~ "Fråga Tore"
  end

  describe "app shell nav" do
    test "shows only Today, Plan, Shop as destinations", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      nav_html = view |> element("header nav") |> render()
      bottom_nav_html = view |> element(~s(nav[data-role="bottom-nav"])) |> render()

      assert nav_html =~ ~s(href="/plan")
      assert nav_html =~ ~s(href="/shop")
      assert nav_html =~ ~s(href="/settings")
      refute nav_html =~ ~s(href="/recipes")
      refute nav_html =~ ~s(href="/prep")
      refute nav_html =~ ~s(href="/cooking")

      assert bottom_nav_html =~ ~s(href="/plan")
      assert bottom_nav_html =~ ~s(href="/shop")
      refute bottom_nav_html =~ ~s(href="/settings")
      refute bottom_nav_html =~ ~s(href="/recipes")
      refute bottom_nav_html =~ ~s(href="/prep")
      refute bottom_nav_html =~ ~s(href="/cooking")
    end
  end

  test "review pill shows when runs need attention", %{conn: conn} do
    pending_review_fixture(home_scope())

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-role="review-pill")
    assert html =~ ~s(href="/review")
  end

  test "review pill is absent when nothing needs review, even with a question waiting", %{
    conn: conn
  } do
    pending_question_fixture(home_scope())
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ ~s(data-role="review-pill")
  end

  defp plan_id_for_today do
    today = Date.utc_today()
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    Tore.Streams.plan(home_scope(), week_start)
  end

  defp seed_tonight_recipe do
    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Chicken gratäng",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    Tore.Planning.assign_recipe(home_scope(), plan_id_for_today(), today_slot_key(), recipe.id, 4)
    recipe
  end

  describe "tonight object sheet" do
    test "long-pressing the tonight card opens a sheet scoped to today with a scoped input",
         %{conn: conn} do
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("open_tonight_sheet", %{})

      html = render(view)
      assert html =~ ~s(phx-submit="tonight_command")

      test_pid = self()

      expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
        [%{role: "user", content: content}] = msgs
        assert content =~ "The user is referring to"
        assert content =~ today_slot_key()
        send(test_pid, :tonight_command_dispatched)

        {:ok, {:message, "done"},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end)

      view
      |> form(~s(form[phx-submit="tonight_command"]), %{command: "make it vegetarian"})
      |> render_submit()

      refute render(view) =~ ~s(phx-submit="tonight_command")

      assert_receive :tonight_command_dispatched, 2_000

      # Wait for the run to finish, or it keeps writing after the test's database is gone.
      eventually(fn -> render(view) =~ "Klar" end)
    end

    test "escape closes the tonight sheet without dispatching", %{conn: conn} do
      seed_tonight_recipe()
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("open_tonight_sheet", %{})

      assert render(view) =~ ~s(phx-submit="tonight_command")

      view
      |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
      |> render_hook("close_tonight_sheet", %{})

      refute render(view) =~ ~s(phx-submit="tonight_command")
    end

    test "no sheet opens on the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "open_tonight_sheet", %{})

      refute render(view) =~ ~s(phx-submit="tonight_command")
    end
  end

  test "says the household is eating out tonight instead of nothing planned", %{
    conn: conn,
    user: user
  } do
    today = Date.utc_today()
    monday = Date.add(today, -(Date.day_of_week(today) - 1))
    day = Enum.at(~w(mon tue wed thu fri sat sun), Date.day_of_week(today) - 1)

    {:ok, _} =
      Tore.Planning.eat_out(
        home_scope(),
        Tore.Streams.plan(home_scope(), monday),
        "#{day}_dinner",
        %{
          user_id: user.id
        }
      )

    {:ok, _lv, html} = live(conn, "/")
    assert html =~ "Äter ute ikväll"
    refute html =~ "Inget planerat"
  end
end
