defmodule ToreWeb.RecipeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Tore.Recipes

  setup do
    user = user_fixture(name: "Gustaf")
    {:ok, recipe} = Recipes.create(home_scope(), %{title: "Roast chicken", recipe_type: :meal})
    %{user: user, recipe: recipe}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  describe "page render" do
    test "shows recipe grid and single control card", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      assert html =~ "Recept"
      assert html =~ recipe.title
      assert html =~ "Sök recept"
      assert html =~ "Vad kan vi laga ikväll?"
    end

    test "more filters hidden by default", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      refute html =~ "quick"
      refute html =~ "Alla"
    end
  end

  describe "toggle_more_filters" do
    test "expands and collapses filter panel", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "toggle_more_filters")
      assert html =~ "quick"
      assert html =~ "Alla"
      html = render_click(lv, "toggle_more_filters")
      refute html =~ "Alla"
    end
  end

  describe "live image update" do
    test "renders the proxy src when an image broadcast arrives", %{conn: conn, user: user} do
      # A recipe with no image — inserted directly so no async image task fires.
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      refute render(lv) =~ "/images/recipes/#{recipe.id}"

      Phoenix.PubSub.broadcast(
        Tore.PubSub,
        Tore.Recipes.topic(home_scope()),
        {:recipe_image, recipe.id, "recipes/#{recipe.id}/abc.jpg"}
      )

      assert render(lv) =~ "/images/recipes/#{recipe.id}"
    end
  end

  describe "get_ideas" do
    test "shows coming soon flash", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "get_ideas")
      assert html =~ "Kommer snart"
    end
  end

  describe "filter_type" do
    test "filters recipes by type", %{conn: conn, user: user} do
      {:ok, _} = Recipes.create(home_scope(), %{title: "Salsa verde", recipe_type: :component})
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "filter_type", %{"type" => "component"})
      assert html =~ "Salsa verde"
      refute html =~ "Roast chicken"
    end
  end

  describe "search" do
    test "filters recipes by title", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_change(lv, "search", %{"query" => "roast"})
      assert html =~ "Roast chicken"
    end

    test "empty search shows all recipes", %{conn: conn, user: user, recipe: recipe} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_change(lv, "search", %{"query" => "xyz"})
      html = render_change(lv, "search", %{"query" => ""})
      assert html =~ recipe.title
    end
  end

  describe "ingredient editor" do
    test "shows ingredient rows when editing a recipe", %{conn: conn, user: user} do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Pasta",
          recipe_type: :meal,
          ingredients: [%{name: "Spaghetti", quantity: "200", unit: "g"}]
        })

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
      html = render_click(lv, "edit_recipe")
      assert html =~ ~s(value="Spaghetti")
      assert html =~ ~s(value="200")
    end

    test "add_ingredient_row appends a blank row", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "new_recipe")
      html = render_click(lv, "add_ingredient_row")
      assert html =~ ~s(placeholder="Ingrediens")
    end

    test "remove_ingredient_row removes a row", %{conn: conn, user: user} do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Pasta",
          recipe_type: :meal,
          ingredients: [%{name: "Spaghetti", quantity: "200", unit: "g"}]
        })

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "edit_recipe")
      html = render_click(lv, "remove_ingredient_row", %{"index" => "0"})
      refute html =~ ~s(value="Spaghetti")
    end

    test "saving recipe persists ingredient rows", %{conn: conn, user: user} do
      {:ok, recipe} = Recipes.create(home_scope(), %{title: "Pasta", recipe_type: :meal})
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "edit_recipe")

      html =
        render_submit(lv, "save_recipe", %{
          "recipe" => %{
            "title" => "Pasta",
            "recipe_type" => "meal",
            "prep_time_minutes" => "",
            "cook_time_minutes" => "",
            "base_servings" => "",
            "tags" => "",
            "source_url" => "",
            "instructions" => ""
          },
          "ingredients" => %{
            "0" => %{"name" => "Spaghetti", "quantity" => "200", "unit" => "g"}
          }
        })

      refute html =~ "Could not"
      updated = Recipes.get!(home_scope(), recipe.id)
      assert length(updated.recipe_ingredients) == 1
      assert hd(updated.recipe_ingredients).ingredient.name == "Spaghetti"
    end
  end
end
