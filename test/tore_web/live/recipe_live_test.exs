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
          }
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
      # Pasta isn't all at home, so Cook now asks first; the servings go along.
      lv |> element(~s(button[data-role="start-cooking"])) |> render_click()
      assert has_element?(lv, ~s(a[data-role="cook-anyway"][href*="servings=6"]))
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

    test "another day moves it there, and the same day again takes it off", %{
      conn: conn,
      user: user,
      pasta: pasta
    } do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes?id=#{pasta.id}")
      lv |> element(~s([data-role="put-on-week"])) |> render_click()

      [first, second] = for n <- [1, 2], do: Date.add(Tore.Clock.today(), n)

      on = fn date ->
        plan = Tore.Streams.plan(home_scope(), Tore.Streams.monday(date))
        {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
        get_in(state.slots, [Tore.Streams.slot_key(date), :recipe_id])
      end

      lv |> element(~s([data-day="#{Date.to_iso8601(first)}"])) |> render_click()
      lv |> element(~s([data-day="#{Date.to_iso8601(second)}"])) |> render_click()
      assert on.(first) == nil
      assert on.(second) == pasta.id
      assert has_element?(lv, ~s([data-day="#{Date.to_iso8601(second)}"][aria-pressed="true"]))

      assert lv |> element(~s([data-role="put-done"])) |> render() =~
               "Lagd på #{String.downcase(ToreWeb.Dates.weekday(second))}"

      lv |> element(~s([data-day="#{Date.to_iso8601(second)}"])) |> render_click()
      assert on.(second) == nil
      refute has_element?(lv, ~s([data-role="put-done"]))
    end

    test "baking is started, not planned", %{conn: conn, user: user} do
      {:ok, buns} =
        Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking})

      {:ok, lv, html} = live(authed(conn, user), "/recipes?id=#{buns.id}")

      assert html =~ "Baka nu"
      assert lv |> element(~s([data-role="collection"])) |> render() =~ "Bakning"
      refute has_element?(lv, ~s([data-role="put-on-week"]))
    end
  end

  describe "collections" do
    test "Bakning shows the baking, and only that", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _} =
        Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking})

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")

      html = lv |> element(~s([data-collection="baking"])) |> render_click()

      assert html =~ "Kanelbullar"
      refute html =~ recipe.title
      assert has_element?(lv, ~s([data-collection="baking"][aria-selected="true"]))
    end
  end

  describe "views" do
    test "the gallery groups by collection, and the list is remembered", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      {:ok, _} =
        Recipes.create(home_scope(), %{title: "Kanelbullar", recipe_type: :baking})

      {:ok, lv, html} = live(authed(conn, user), "/recipes")
      assert has_element?(lv, ~s([data-view="gallery"][aria-selected="true"]))
      assert has_element?(lv, ~s([data-collection="meal"]))
      assert has_element?(lv, ~s([data-collection="baking"]))
      assert html =~ recipe.title

      lv |> element(~s([data-view="list"])) |> render_click()
      assert has_element?(lv, ~s([data-view="list"][aria-selected="true"]))

      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      assert has_element?(lv, ~s([data-view="list"][aria-selected="true"]))
      assert render(lv) =~ "Kanelbullar"
    end

    test "search opens from the toolbar", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      refute has_element?(lv, ~s(form[phx-change="search"]))
      render_click(lv, "toggle_search")
      assert has_element?(lv, ~s(form[phx-change="search"]))
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

  describe "live recipe update" do
    test "shows a picture pi drew once the recipe changes", %{conn: conn, user: user} do
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

      {:ok, _} =
        Recipes.update(home_scope(), recipe, %{
          image_path: "households/#{home_scope().household_id}/recipes/#{recipe.id}/abc.jpg"
        })

      Phoenix.PubSub.broadcast(
        Tore.PubSub,
        Tore.Recipes.topic(home_scope()),
        {:recipe_changed, recipe.id}
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

    test "stars the recipe, and takes the star away", %{conn: conn, user: user, recipe: recipe} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
      render_click(lv, "toggle_recipe_menu")

      lv |> element(~s([data-role="toggle-favorite"])) |> render_click()
      assert [%{id: id}] = Recipes.list_favorites(home_scope())
      assert id == recipe.id

      render_click(lv, "toggle_recipe_menu")

      assert lv |> element(~s([data-role="toggle-favorite"])) |> render() =~
               "Ta bort från favoriter"

      lv |> element(~s([data-role="toggle-favorite"])) |> render_click()
      assert Recipes.list_favorites(home_scope()) == []
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
          }
        )

      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "smör"})
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: buns.id]}")

      assert view |> element(~s([data-role="at-home"])) |> render() =~ "Saknas: kanel"
      refute has_element?(view, ~s([data-role="ask-tore"]))
      refute render(view) =~ "Saknas något?"
      view |> element(~s(#recipe-actions button[aria-label="Mer"])) |> render_click()
      assert view |> element(~s([data-role="ask-tore"])) |> render() =~ "q=Om+Kanelbullar"

      view |> element(~s([data-role="at-home"] button)) |> render_click()
      assert has_element?(view, "#home-added")

      list_id = Tore.Streams.shop_list(home_scope(), Tore.Streams.monday(Tore.Clock.today()))
      {:ok, state} = Tore.Shop.load_list(home_scope(), list_id)
      assert state.items |> Map.values() |> Enum.map(& &1.name) == ["kanel"]

      # Opened again, it says so straight away: there's nothing left to put on the list.
      {:ok, again, _} = live(authed(conn, user), ~p"/recipes?#{[id: buns.id]}")
      assert has_element?(again, "#home-added")
      assert has_element?(again, ~s([data-role="to-pantry"][href="/pantry"]))
      refute has_element?(again, ~s([data-role="at-home"] button))
    end
  end

  describe "before cooking" do
    setup do
      {:ok, stew} =
        Recipes.create(
          home_scope(),
          %{
            title: "Kycklinggryta",
            recipe_type: :meal,
            ingredients: [%{name: "kyckling"}, %{name: "gul lök"}, %{name: "crème fraîche"}]
          }
        )

      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "kyckling"})
      %{stew: stew}
    end

    test "with everything at home, Cook now goes straight to cook mode", %{conn: conn, user: user} do
      {:ok, buns} =
        Recipes.create(home_scope(), %{title: "Bullar", ingredients: [%{name: "salt"}]})

      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: buns.id]}")
      assert view |> element(~s(a[data-role="start-cooking"])) |> render() =~ "/cook"
    end

    test "ticking what you have is free; all ticked, you cook", %{
      conn: conn,
      user: user,
      stew: stew
    } do
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: stew.id]}")

      view |> element(~s(button[data-role="start-cooking"])) |> render_click()
      assert has_element?(view, ~s([data-role="before-cooking"]))
      assert has_element?(view, ~s([data-role="cook-anyway"]))
      refute has_element?(view, ~s([data-role="cook-with"]))

      view |> element(~s([data-missing="gul lök"] button)) |> render_click()
      view |> element(~s([data-missing="crème fraîche"] button)) |> render_click()

      assert view |> element(~s([data-role="cook-with"])) |> render() =~ "Laga nu"
      refute has_element?(view, "#before-cooking-check")
      refute has_element?(view, ~s([data-role="cook-anyway"]))
    end

    test "Check asks once for the rest and cooks with the swaps", %{
      conn: conn,
      user: user,
      stew: stew
    } do
      Mox.set_mox_global()

      Mox.expect(Tore.MockLLM, :text, fn _system, user_msg, _opts ->
        sent = Jason.decode!(user_msg)
        assert sent["missing"] == ["crème fraîche"]
        assert sent["they_have"] == "gräddfil"

        {:ok,
         %{
           "swaps" => [
             %{"for" => "crème fraîche", "use" => "gräddfil", "note" => "Rör ner på låg värme."}
           ]
         }, %{}}
      end)

      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: stew.id]}")
      view |> element(~s(button[data-role="start-cooking"])) |> render_click()
      view |> element(~s([data-missing="gul lök"] button)) |> render_click()
      view |> element("#before-cooking-check") |> render_submit(%{offered: "gräddfil"})

      assert render_async(view) =~ "Rör ner på låg värme."
      link = view |> element(~s([data-role="cook-with"])) |> render()
      assert link =~ "Laga med det här"
      assert link =~ "swaps[0][use]=gr%C3%A4ddfil"
      assert has_element?(view, ~s([data-role="cook-anyway"]))
      assert Tore.Pantry.at_home(home_scope(), ["gräddfil"]).missing == ["gräddfil"]
    end
  end

  describe "a hand-written recipe" do
    import Tore.FakePi
    setup :fake_pi

    test "is finished by pi once saved: steps and a picture", %{
      conn: conn,
      user: user,
      pi_log: log
    } do
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
      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))["message"]
      assert prompt =~ "Background job: finish_recipe."
      assert prompt =~ "Recipe #{recipe.id}."
    end
  end

  describe "a meal of parts" do
    setup do
      {:ok, sauce} =
        Recipes.create(
          home_scope(),
          %{
            title: "Bearnaise",
            recipe_type: :component,
            base_servings: 4,
            steps: Jason.encode!([%{"order" => 1, "phase" => "SÅS", "action" => "Smält smöret"}]),
            ingredients: [%{name: "Smör", quantity: Decimal.new(200), unit: "g"}]
          }
        )

      {:ok, meat} =
        Recipes.create(
          home_scope(),
          %{
            title: "Stekt entrecote",
            recipe_type: :component,
            base_servings: 2,
            instructions: "Stek köttet.",
            ingredients: [%{name: "Entrecote", quantity: Decimal.new(400), unit: "g"}]
          }
        )

      {:ok, meal} =
        Recipes.put_together(
          home_scope(),
          %{title: "Entrecote med bearnaise", servings: 4, part_ids: [meat.id, sauce.id]}
        )

      %{sauce: sauce, meat: meat, meal: meal}
    end

    test "shows its parts, their ingredients under each, and their methods until cooked", %{
      conn: conn,
      user: user,
      sauce: sauce,
      meat: meat,
      meal: meal
    } do
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: meal.id]}")

      parts = view |> element(~s([data-role="parts"])) |> render()
      assert parts =~ ~s(href="/recipes?id=#{meat.id}")
      assert parts =~ ~s(href="/recipes?id=#{sauce.id}")

      meat_list = view |> element(~s([data-part="#{meat.id}"])) |> render()
      assert meat_list =~ "Stekt entrecote"
      assert meat_list =~ "Entrecote"
      assert meat_list =~ "800 g"

      method = view |> element(~s([data-role="part-methods"])) |> render()
      assert method =~ "Stek köttet."
      assert method =~ "Smält smöret"
    end

    test "a part says which meals it's in", %{conn: conn, user: user, sauce: sauce, meal: meal} do
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes?#{[id: sauce.id]}")

      assert view |> element(~s([data-role="part-of"])) |> render() =~
               ~s(href="/recipes?id=#{meal.id}")
    end

    test "Sätt ihop puts a new meal together from the recipes picked", %{
      conn: conn,
      user: user,
      sauce: sauce,
      meat: meat,
      meal: meal
    } do
      {:ok, view, _} = live(authed(conn, user), ~p"/recipes")
      view |> element(~s([data-role="new-recipe"])) |> render_click()
      view |> element(~s([data-role="compose"])) |> render_click()

      # A meal that has parts isn't offered as one.
      refute has_element?(view, ~s(#compose input[value="#{meal.id}"]))

      assert view |> form("#compose", %{title: "Middag", part_ids: [sauce.id]}) |> render_submit() =~
               "Välj minst två"

      view
      |> form("#compose", %{title: "Biff med bearnaise", part_ids: [meat.id, sauce.id]})
      |> render_submit()

      new = Enum.find(Recipes.list(home_scope()), &(&1.title == "Biff med bearnaise"))
      assert Enum.map(Recipes.get!(home_scope(), new.id).parts, & &1.id) == [meat.id, sauce.id]
      assert has_element?(view, ~s([data-role="parts"]))
    end
  end
end
