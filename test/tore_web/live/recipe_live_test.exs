defmodule ToreWeb.RecipeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Tore.Recipes

  setup do
    user = user_fixture(name: "Gustaf")
    {:ok, recipe} = Recipes.create(home_scope(), %{title: "Roast chicken", recipe_type: :meal})
    %{user: user, recipe: recipe}
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  describe "page render" do
    test "shows the recipes and the search", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      assert html =~ "Recept"
      assert html =~ recipe.title
      assert html =~ "Sök recept"
    end

    test "more filters hidden by default", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      refute html =~ "quick"
      refute html =~ "Sortera"
    end
  end

  describe "a new recipe" do
    import Mox
    setup :verify_on_exit!
    setup :set_mox_from_context

    @page """
    <html><head><script type="application/ld+json">
    {"@type": "Recipe", "name": "Morotssoppa", "recipeYield": "4",
     "recipeIngredient": ["6 morötter"], "recipeInstructions": ["Koka."]}
    </script></head></html>
    """

    @soup %{
      "title" => "Morotssoppa",
      "base_servings" => 4,
      "ingredients" => [%{"item" => "morot", "quantity" => 6, "unit" => "st"}],
      "steps" => [%{"order" => 1, "phase" => "COOKING", "action" => "Koka.", "ingredients" => []}],
      "tags" => []
    }

    test "starts from a link, and writing it yourself is the way out", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")

      html = render_click(lv, "new_recipe")
      assert has_element?(lv, "#import-link input[name=url]")
      assert html =~ "Hämta recept"
      refute has_element?(lv, ~s(input[name="recipe[title]"]))

      lv
      |> form("#import-link", %{url: "https://example.com/soppa"})
      |> put_submitter(~s(button[name="write"]))
      |> render_submit()

      assert has_element?(lv, ~s(input[name="recipe[title]"]))

      assert has_element?(
               lv,
               ~s(input[name="recipe[source_url]"][value="https://example.com/soppa"])
             )
    end

    test "a link is read in and the recipe opens", %{conn: conn, user: user} do
      stub(Tore.MockHTTP, :fetch, fn
        "https://example.com/soppa" -> {:ok, @page}
        _ -> {:error, :not_found}
      end)

      stub(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, @soup, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}}
      end)

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "new_recipe")

      html = lv |> form("#import-link", %{url: " https://example.com/soppa "}) |> render_submit()
      assert html =~ "Läser receptet"

      assert eventually(fn ->
               Enum.any?(Recipes.list(home_scope()), &(&1.title == "Morotssoppa"))
             end)

      _ = render(lv)
      [recipe] = Enum.filter(Recipes.list(home_scope()), &(&1.title == "Morotssoppa"))
      assert_patch(lv, "/recipes?id=#{recipe.id}")
    end

    test "a page that isn't a recipe says so, next to the field", %{conn: conn, user: user} do
      stub(Tore.MockHTTP, :fetch, fn _ -> {:ok, "<html><body>Hej</body></html>"} end)

      stub(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, %{"not_a_recipe" => true}, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}}
      end)

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "new_recipe")
      lv |> form("#import-link", %{url: "https://example.com/hej"}) |> render_submit()

      assert eventually(fn -> render(lv) =~ "inte ut som ett recept" end)
      html = render(lv)
      assert has_element?(lv, ~s(#import-link input[aria-invalid="true"]))
      assert html =~ "Skriv in det själv"
    end

    test "a link shared to Tore is read in straight away, and the address drops it", %{
      conn: conn,
      user: user
    } do
      stub(Tore.MockHTTP, :fetch, fn
        "https://example.com/soppa" -> {:ok, @page}
        _ -> {:error, :not_found}
      end)

      stub(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, @soup, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}}
      end)

      # Instagram and others put the link in `text`, among other words.
      {:ok, lv, _html} =
        live(
          authed(conn, user),
          "/recipes?text=Kolla%20h%C3%A4r%20https%3A%2F%2Fexample.com%2Fsoppa"
        )

      assert eventually(fn ->
               Enum.any?(Recipes.list(home_scope()), &(&1.title == "Morotssoppa"))
             end)

      _ = render(lv)
      [recipe] = Enum.filter(Recipes.list(home_scope()), &(&1.title == "Morotssoppa"))
      assert_patch(lv, "/recipes?id=#{recipe.id}")
    end

    test "something shared without a link opens the sheet and says what's missing", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes?text=Morotssoppa")

      assert has_element?(lv, "#import-error")
      assert has_element?(lv, ~s(#import-link input[value="Morotssoppa"]))
    end

    test "something that isn't a link is caught before anything is fetched", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "new_recipe")

      html = lv |> form("#import-link", %{url: "morotssoppa"}) |> render_submit()
      assert html =~ "https://"
      assert has_element?(lv, "#import-error")
      # What was typed stays, so the error sits next to its cause.
      assert has_element?(lv, ~s(#import-link input[value="morotssoppa"]))

      # Writing it in by hand from there: it wasn't a link, so it's taken as the name.
      lv |> form("#import-link") |> put_submitter(~s(button[name="write"])) |> render_submit()
      assert has_element?(lv, ~s(input[name="recipe[title]"][value="morotssoppa"]))
      assert has_element?(lv, ~s(input[name="recipe[source_url]"][value=""]))
    end
  end

  describe "a recipe's page" do
    setup do
      {:ok, pasta} =
        Recipes.create(
          home_scope(),
          %{
            title: "Pasta",
            recipe_type: :meal,
            base_servings: 4,
            ingredients: [%{name: "Spaghetti", quantity: Decimal.new(400), unit: "g"}]
          },
          image: false
        )

      %{pasta: pasta}
    end

    test "servings scale the amounts", %{conn: conn, user: user, pasta: pasta} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes?id=#{pasta.id}")
      assert lv |> element(~s([data-role="amount"])) |> render() =~ "400 g"

      lv |> element(~s(button[phx-value-by="1"])) |> render_click()
      lv |> element(~s(button[phx-value-by="1"])) |> render_click()

      assert lv |> element(~s([data-role="servings"])) |> render() =~ "6"
      assert lv |> element(~s([data-role="amount"])) |> render() =~ "600 g"
      assert has_element?(lv, ~s(a[data-role="start-cooking"][href*="servings=6"]))
    end

    test "it goes on a day of the week, and Undo puts the day back", %{
      conn: conn,
      user: user,
      pasta: pasta
    } do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes?id=#{pasta.id}")
      lv |> element(~s([data-role="put-on-week"])) |> render_click()

      tomorrow = Date.add(Tore.Clock.today(), 1)
      plan = Tore.Streams.plan(home_scope(), Tore.Streams.monday(tomorrow))
      key = Tore.Streams.slot_key(tomorrow)

      html = lv |> element(~s([data-day="#{Date.to_iso8601(tomorrow)}"])) |> render_click()
      assert html =~ "Ångra"
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
      assert %{recipe_id: id, servings: 4} = state.slots[key]
      assert id == pasta.id

      lv |> element("button", "Ångra") |> render_click()
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
      assert state.slots[key] in [nil] or state.slots[key].recipe_id == nil
    end

    test "baking is started, not planned", %{conn: conn, user: user} do
      {:ok, buns} =
        Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking}, image: false)

      {:ok, lv, html} = live(authed(conn, user), "/recipes?id=#{buns.id}")

      assert html =~ "Baka nu"
      assert lv |> element(~s([data-role="collection"])) |> render() =~ "Bakning"
      refute has_element?(lv, ~s([data-role="put-on-week"]))
    end
  end

  describe "collections" do
    test "Bakning shows the baking, and only that", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _} =
        Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking}, image: false)

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")

      html = lv |> element(~s([data-collection="baking"])) |> render_click()

      assert html =~ "Kanelbullar"
      refute html =~ recipe.title
      assert has_element?(lv, ~s([data-collection="baking"][aria-selected="true"]))
    end
  end

  describe "toggle_more_filters" do
    test "expands and collapses filter panel", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "toggle_more_filters")
      assert html =~ "quick"
      assert html =~ "Sortera"
      html = render_click(lv, "toggle_more_filters")
      refute html =~ "Sortera"
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
        {:recipe_image, recipe.id,
         "households/#{home_scope().household_id}/recipes/#{recipe.id}/abc.jpg"}
      )

      assert render(lv) =~ "/images/recipes/#{recipe.id}"
    end
  end

  describe "the recipe's menu" do
    test "can ask for a new picture", %{conn: conn, user: user, recipe: recipe} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "toggle_recipe_menu")

      html = lv |> element(~s(button[phx-click="make_image"])) |> render_click()

      assert html =~ "Gör en bild"
      refute has_element?(lv, ~s(button[phx-click="make_image"]))
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
      lv |> form("#import-link") |> put_submitter(~s(button[name="write"])) |> render_submit()
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

  describe "what's at home" do
    test "the page says what's missing and puts it on the list", %{conn: conn, user: user} do
      Mox.set_mox_global()
      Mox.stub(Tore.MockLLM, :text, fn _s, _u, _o -> {:ok, %{"section" => "other"}, %{}} end)

      {:ok, buns} =
        Recipes.create(
          home_scope(),
          %{
            title: "Kanelbullar",
            recipe_type: :baking,
            ingredients: [%{name: "smör"}, %{name: "kanel"}]
          },
          image: false
        )

      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "smör"})
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: buns.id]}")

      assert view |> element(~s([data-role="at-home"])) |> render() =~ "Saknas: kanel"
      assert view |> element(~s([data-role="ask-tore"])) |> render() =~ "q=Om+Kanelbullar"

      view |> element(~s([data-role="at-home"] button)) |> render_click()
      assert has_element?(view, "#home-added")

      list_id = Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(Tore.Clock.today()))
      {:ok, state} = Tore.Shop.load_list(home_scope(), list_id)
      assert state.items |> Map.values() |> Enum.map(& &1.name) == ["kanel"]
    end
  end

  describe "steps for cook mode" do
    test "are written when a hand-written recipe is saved", %{conn: conn, user: user} do
      Mox.set_mox_global()

      # Saving also asks about the picture and the new ingredient; one answer serves all three.
      Mox.stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
        steps = [%{"order" => 1, "action" => "Koka linserna", "ingredients" => ["linser"]}]
        {:ok, %{"steps" => steps, "prompt" => "A bowl of soup.", "section" => "dry_goods"}, %{}}
      end)

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "new_recipe")

      render_submit(lv, "save_recipe", %{
        "recipe" => %{
          "title" => "Linssoppa",
          "recipe_type" => "meal",
          "prep_time_minutes" => "",
          "cook_time_minutes" => "",
          "base_servings" => "",
          "tags" => "",
          "source_url" => "",
          "instructions" => "Koka linserna mjuka."
        },
        "ingredients" => %{"0" => %{"name" => "linser", "quantity" => "", "unit" => ""}}
      })

      [recipe] = Recipes.search(home_scope(), "Linssoppa")

      assert Enum.any?(1..50, fn _ ->
               Process.sleep(10)
               Recipes.get!(home_scope(), recipe.id).steps != nil
             end)
    end
  end
end
