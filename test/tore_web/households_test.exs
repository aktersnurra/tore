defmodule ToreWeb.HouseholdsTest do
  @moduledoc "Someone signed in to a second household sees only that household."
  use ToreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp insert_recipe(household_id, title) do
    # Straight to the Repo: Recipes.create/2 starts an image task that would call the LLM.
    Tore.Repo.insert!(%Tore.Recipes.Recipe{
      household_id: household_id,
      title: title,
      recipe_type: :meal
    })
  end

  setup do
    household = household_fixture(%{name: "Andra"})
    %{member: user_fixture(household: household), scope: scope_fixture(household)}
  end

  test "the recipe list shows the member's household only", %{
    conn: conn,
    member: member,
    scope: scope
  } do
    insert_recipe(home_scope().household_id, "Hemmets ärtsoppa")
    insert_recipe(scope.household_id, "Andras pannkakor")

    {:ok, _lv, html} = live(authed(conn, member), "/recipes")

    assert html =~ "Andras pannkakor"
    refute html =~ "Hemmets ärtsoppa"
  end

  test "the planner shows the member's own plan", %{conn: conn, member: member, scope: scope} do
    week = Tore.Streams.monday(Date.utc_today())
    ours = insert_recipe(scope.household_id, "Andras pannkakor")
    theirs = insert_recipe(home_scope().household_id, "Hemmets ärtsoppa")

    {:ok, _} =
      Tore.Planning.assign_recipe(scope, Tore.Streams.plan(scope, week), "mon_dinner", ours.id, 4)

    {:ok, _} =
      Tore.Planning.assign_recipe(
        home_scope(),
        Tore.Streams.plan(home_scope(), week),
        "tue_dinner",
        theirs.id,
        4
      )

    {:ok, _lv, html} = live(authed(conn, member), "/plan")

    assert html =~ "Andras pannkakor"
    refute html =~ "Hemmets ärtsoppa"
  end
end
