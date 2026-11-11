defmodule ToreWeb.CookLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Tore.Recipes

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(name: "Gustaf")

    steps = [
      %{
        "phase" => "MISE EN PLACE",
        "order" => 1,
        "action" => "Skiva vitlöken",
        "ingredients" => ["Vitlök"],
        "duration_minutes" => nil
      },
      %{
        "phase" => "TILLAGNING",
        "order" => 2,
        "action" => "Fräs vitlöken i oljan",
        "ingredients" => ["vitlök", "olivolja"],
        "duration_minutes" => 2
      }
    ]

    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Pasta",
        recipe_type: :meal,
        steps: Jason.encode!(steps),
        ingredients: [%{name: "Vitlök", quantity: "2", unit: "klyftor"}]
      })

    %{conn: Plug.Test.init_test_session(conn, %{user_id: user.id}), recipe: recipe}
  end

  defp eventually(view, text, tries \\ 40) do
    cond do
      render(view) =~ text -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(view, text, tries - 1)
    end
  end

  test "opens on what to take out, then steps through the recipe", %{conn: conn, recipe: recipe} do
    {:ok, view, _html} = live(conn, ~p"/recipes/#{recipe.id}/cook")

    assert eventually(view, "Ta fram det här")
    assert render(view) =~ "2 klyftor Vitlök"
    assert render(view) =~ "1 av 3"

    html = view |> element(~s([data-role="step-card"])) |> render_click()
    assert html =~ "Skiva vitlöken"
    assert html =~ "Mise en place"
    assert_patch(view, ~p"/recipes/#{recipe.id}/cook?#{[from: "/recipes", step: 2]}")

    html = view |> element(~s([data-role="step-card"])) |> render_click()
    assert html =~ "Fräs vitlöken i oljan"
    assert html =~ "2 min"
    # The amount comes from the recipe; an ingredient it doesn't list is shown by name.
    assert html =~ "2 klyftor Vitlök"
    assert html =~ "olivolja"
    assert html =~ "Klar"
  end

  test "a reload lands on the same card", %{conn: conn, recipe: recipe} do
    {:ok, view, _html} = live(conn, ~p"/recipes/#{recipe.id}/cook?step=3")

    assert eventually(view, "Fräs vitlöken i oljan")
    assert render(view) =~ "3 av 3"
  end

  test "every step is one tap away, and tapping one goes there", %{conn: conn, recipe: recipe} do
    {:ok, view, _html} = live(conn, ~p"/recipes/#{recipe.id}/cook")
    assert eventually(view, "Ta fram det här")

    refute has_element?(view, "#cook-mode-overview")
    render_click(view, "toggle_overview")
    assert has_element?(view, "#cook-mode-overview", "Fräs vitlöken i oljan")

    view |> element(~s(#cook-mode-overview button[phx-value-to="2"])) |> render_click()

    refute has_element?(view, "#cook-mode-overview")
    assert render(view) =~ "3 av 3"
  end

  test "the cross goes back to where cooking started", %{conn: conn, recipe: recipe} do
    {:ok, view, _html} = live(conn, ~p"/recipes/#{recipe.id}/cook?from=/today")
    assert eventually(view, "Ta fram det här")

    assert has_element?(view, ~s(#cook-mode a[href="/today"]))
  end

  test "says so when a recipe without steps can't get them", %{conn: conn} do
    {:ok, recipe} = Recipes.create(home_scope(), %{title: "Soppa", recipe_type: :meal})
    expect(Tore.MockLLM, :text, fn _system, _user, _opts -> {:error, :timeout} end)

    {:ok, view, _html} = live(conn, ~p"/recipes/#{recipe.id}/cook")

    assert eventually(view, "Det gick inte att skriva stegen")
    assert render(view) =~ "Receptet är oförändrat"
  end

  test "another household's recipe can't be opened", %{conn: conn} do
    other = scope_fixture(household_fixture())
    {:ok, recipe} = Recipes.create(other, %{title: "Hemlig", recipe_type: :meal})

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/recipes/#{recipe.id}/cook") end
  end
end
