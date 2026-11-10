defmodule Tore.RecipesScrapeTest do
  use Tore.DataCase, async: false
  import Mox
  alias Tore.Recipes

  setup :verify_on_exit!

  @ld_json_html """
  <html><head>
  <script type="application/ld+json">
  {"@type": "Recipe", "name": "Scraped Pasta", "recipeIngredient": ["pasta", "sauce"]}
  </script>
  </head><body></body></html>
  """

  @plain_html "<html><body><h1>A recipe page</h1></body></html>"

  describe "scrape_and_create/1" do
    test "Parser result still passes through LLM normaliser for reformatting + translation" do
      Tore.MockHTTP
      |> expect(:fetch, fn "https://example.com/recipe" -> {:ok, @ld_json_html} end)

      Tore.MockLLM
      |> expect(:text, fn _system, _user, _opts ->
        {:ok, %{"title" => "Skrapad Pasta", "ingredients" => [], "steps" => [], "tags" => []},
         %{}}
      end)

      assert {:ok, recipe} = Recipes.scrape_and_create(home_scope(), "https://example.com/recipe")
      assert recipe.title == "Skrapad Pasta"
      assert recipe.source_url == "https://example.com/recipe"
    end

    test "falls back to LLM when Parser returns not_found" do
      Tore.MockHTTP
      |> expect(:fetch, fn "https://example.com/plain" -> {:ok, @plain_html} end)

      Tore.MockLLM
      # 1st text call: check_html_parseable
      |> expect(:text, fn _system, _user, _opts -> {:ok, %{"parseable" => true}, %{}} end)
      # 2nd text call: extract_from_html (raw recipe JSON, shaped downstream)
      |> expect(:text, fn _system, _user, _opts ->
        {:ok, %{"title" => "LLM Recipe", "ingredients" => [], "steps" => []}, %{}}
      end)

      assert {:ok, recipe} = Recipes.scrape_and_create(home_scope(), "https://example.com/plain")
      assert recipe.title == "LLM Recipe"
    end

    test "propagates HTTP error" do
      Tore.MockHTTP
      |> expect(:fetch, fn _ -> {:error, :timeout} end)

      assert {:error, :timeout} =
               Recipes.scrape_and_create(home_scope(), "https://example.com/bad")
    end
  end
end
