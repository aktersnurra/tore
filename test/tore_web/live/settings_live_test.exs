defmodule ToreWeb.SettingsLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "lists the members, with no codes or roles", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/settings/members")

    assert html =~ "Gustaf"
    assert html =~ user.username
    refute has_element?(view, ~s(button[phx-click="regenerate_code"]))
    refute has_element?(view, ~s(form[phx-submit="add_user"]))
  end

  describe "members" do
    defp add_member(view, username) do
      view |> form(~s(form[phx-submit="add_member"]), %{username: username}) |> render_submit()
    end

    test "adding someone who hasn't signed in says they join at their first sign-in", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/members")

      html = add_member(view, "bo")

      assert html =~ "bo går med vid sin första inloggning."
      assert html =~ "Går med vid första inloggningen"
    end

    test "adding someone already a member says so", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/members")

      assert add_member(view, user.username) =~ "Personen är redan medlem."
    end

    test "removing a member closes their open pages and their next request is elsewhere", %{
      conn: conn
    } do
      partner = user_fixture(name: "Partner")
      ToreWeb.Endpoint.subscribe("users_sessions:#{partner.id}")
      {:ok, view, _html} = live(conn, ~p"/settings/members")

      html =
        view
        |> element(~s(button[phx-click="remove_member"][phx-value-id="#{partner.id}"]))
        |> render_click()

      refute html =~ "Partner"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      {_partner, scope} = Tore.Accounts.get_session(partner.id)
      assert scope.household_id != home_scope().household_id
    end

    test "the switcher appears only for someone in two or more households", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      refute has_element?(view, ~s(a[href="/settings/households"]))

      # Home holds something, so being added elsewhere adds a household rather than moving them.
      Tore.Repo.insert!(%Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Ärtsoppa",
        recipe_type: :meal
      })

      other = household_fixture(%{name: "Stugan"})
      {:ok, {:added, _}} = Tore.Members.add(scope_fixture(other), user.username)
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert view |> element(~s(a[href="/settings/households"])) |> render() =~ "Dina hushåll"
      {:ok, view, _html} = live(conn, ~p"/settings/households")

      view
      |> element(~s(button[phx-click="switch_household"][phx-value-id="#{other.id}"]))
      |> render_click()

      assert {_user, %{household_id: id}} = Tore.Accounts.get_session(user.id)
      assert id == other.id
    end

    test "someone with the credits claim turns sponsorship on for the household" do
      user =
        user_fixture(name: "Sponsor")
        |> Ecto.Changeset.change(ai_enabled: true)
        |> Tore.Repo.update!()

      conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
      {:ok, view, _html} = live(conn, ~p"/settings/ai")

      view |> element(~s(button[phx-click="toggle_ai_sponsor"])) |> render_click()

      assert Tore.Household.ai_sponsor(home_scope()).id == user.id
    end

    test "someone without the claim sees no switch, and that AI is off", %{conn: conn} do
      Tore.Repo.update_all(Tore.Household.HouseholdSchema,
        set: [ai_sponsor_id: nil]
      )

      {:ok, view, html} = live(conn, ~p"/settings/ai")

      refute has_element?(view, ~s(button[phx-click="toggle_ai_sponsor"]))
      assert html =~ "AI är avstängt för det här hushållet."
    end

    test "renames the household", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/name")

      view
      |> form(~s(form[phx-submit="rename_household"]), %{name: "Rydholms"})
      |> render_submit()

      assert home_household().name == "Rydholms"
    end
  end

  describe "an id the page didn't offer" do
    test "switching to a household you're not in leaves you where you are", %{
      conn: conn,
      user: user
    } do
      other = household_fixture(%{name: "Stugan"})
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_click(view, "switch_household", %{"id" => to_string(other.id)})

      assert render(view) =~ "Inställningar"
      assert {_user, %{household_id: id}} = Tore.Accounts.get_session(user.id)
      assert id == home_scope().household_id
    end

    test "sponsoring without the credits claim changes nothing", %{conn: conn} do
      sponsor = Tore.Household.ai_sponsor(home_scope())
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_click(view, "toggle_ai_sponsor", %{})

      assert render(view) =~ "Inställningar"
      assert Tore.Household.ai_sponsor(home_scope()).id == sponsor.id
    end
  end

  describe "kitchen memory" do
    setup do
      run =
        home_scope()
        |> Tore.Harness.KitchenRun.open(
          %{kind: "memory_update_run", actor: :system, input: %{}},
          DateTime.utc_now()
        )
        |> Tore.Repo.insert!()

      for {store, text} <- [{"profile", "Anna dislikes mushrooms"}, {"notes", "Friday pizza"}] do
        Tore.Repo.insert!(%Tore.Household.Memory{
          household_id: home_scope().household_id,
          store: store,
          text: text,
          run_id: run.id
        })
      end

      :ok
    end

    test "shows both parts and how full each is, with no confidence labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")

      assert html =~ "Anna dislikes mushrooms"
      assert html =~ "Friday pizza"
      assert html =~ "Hushållet"
      assert html =~ "Anteckningar"
      assert html =~ "2 % fullt"
      refute html =~ "säkerhet"
    end

    test "removing an entry forgets it for the household", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      [entry | _] = Tore.Household.Memory.list(home_scope(), "notes")

      html =
        view
        |> element(~s(button[phx-click="forget_memory"][phx-value-id="#{entry.id}"]))
        |> render_click()

      refute html =~ "Friday pizza"
      assert Tore.Household.Memory.list(home_scope(), "notes") == []
    end
  end

  describe "the list" do
    test "each setting is a row with what it's set to, opening its page", %{conn: conn} do
      {:ok, _} = Tore.Household.update_preferences(home_scope(), %{allergies: ["nuts"]})
      {:ok, view, _html} = live(conn, ~p"/settings")

      for {section, value} <- [
            {"name", home_household().name},
            {"members", "#{length(Tore.Accounts.list_members(home_scope()))} personer"},
            {"food", "Nötter"},
            {"memory", "Inga än"},
            {"ai", "$0.00"}
          ] do
        assert view
               |> element(~s(a[data-role="setting"][href="/settings/#{section}"]))
               |> render() =~
                 value
      end

      view |> element(~s(a[href="/settings/food"])) |> render_click()
      assert_patch(view, "/settings/food")

      assert has_element?(
               view,
               ~s(button[phx-click="toggle_allergy"][aria-pressed="true"]),
               "Nötter"
             )

      assert has_element?(view, ~s(a[data-role="settings-back"][href="/settings"]))
    end

    test "light, dark or the system's look is chosen on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      for theme <- ~w(system light dark) do
        assert has_element?(view, ~s([data-role="look"] button[data-phx-theme="#{theme}"]))
      end
    end

    test "a section that isn't one is the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/nope")
      assert has_element?(view, ~s(a[data-role="setting"]))
    end
  end

  test "has a way to sign out", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, ~s(a[href="/logout"][data-method="delete"]))
  end

  test "settings no longer links to run history", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    refute html =~ "Körhistorik"
  end

  test "the household's language is shown and can't be changed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "Svenska"
    refute has_element?(view, ~s(select[name="locale"]))
    refute has_element?(view, ~s(form[phx-change="update_locale"]))
  end
end
