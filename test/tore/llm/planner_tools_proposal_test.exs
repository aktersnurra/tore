defmodule Tore.LLM.PlannerToolsProposalTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Handles
  alias Tore.LLM.PlannerTools
  alias Tore.Planning.State

  @plan %State{}

  defp tool(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  # See memory: Recipes.create/1's async image Task calls MockLLM.text/3 and
  # races expectations. Passing :image_url routes it to the HTTP client.
  defp source_recipe do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)

    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Miso Ramen",
        instructions: "Simmer the broth.",
        base_servings: 4,
        image_url: "https://example.com/ramen.jpg",
        ingredients: [%{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}]
      })

    recipe
  end

  defp variant_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "base_servings" => 4,
      "ingredients" => [%{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}],
      "steps" => [
        %{"order" => 1, "phase" => "COOKING", "action" => "Simmer.", "ingredients" => []}
      ],
      "tags" => ["vegetarian"]
    }
  end

  describe "generate_recipe_variant" do
    test "is a read tool" do
      assert %{kind: :read} = tool("generate_recipe_variant")
    end

    test "returns a loop-terminating proposal carrying provenance" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, variant_payload(), %{prompt_tokens: 10, completion_tokens: 20, cost_usd: 0.001}}
      end)

      args = %{"recipe_ref" => handle.ref, "instruction" => "make it vegetarian"}

      assert {:proposal, %RecipeProposal{} = proposal, pending, @plan} =
               tool("generate_recipe_variant").run.(args, ctx, @plan)

      assert proposal.title == "Vegetarian Miso Ramen"
      assert proposal.source == :generation
      assert proposal.source_recipe_id == recipe.id
      assert pending == %{}
    end

    test "carries a pending slot assignment when slot_key is given" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, variant_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
      end)

      args = %{
        "recipe_ref" => handle.ref,
        "instruction" => "for 6",
        "slot_key" => "mon_dinner",
        "servings" => 6
      }

      assert {:proposal, _proposal, pending, @plan} =
               tool("generate_recipe_variant").run.(args, ctx, @plan)

      assert pending == %{slot_key: "mon_dinner", servings: 6}
    end

    test "rejects an unknown recipe_ref" do
      ctx = %{household_id: 1, handles: %{}}
      args = %{"recipe_ref" => "rcp_nope", "instruction" => "simpler"}

      assert {:error, message} = tool("generate_recipe_variant").run.(args, ctx, @plan)
      assert message =~ "unknown recipe_ref"
    end

    test "propagates a generation failure" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ -> {:error, :timeout} end)

      args = %{"recipe_ref" => handle.ref, "instruction" => "simpler"}
      assert {:error, :timeout} = tool("generate_recipe_variant").run.(args, ctx, @plan)
    end
  end

  describe "import_recipe_from_web" do
    @page_html """
    <html><head><script type="application/ld+json">
    {"@type":"Recipe","name":"Best Miso Ramen","recipeIngredient":["2 msk miso paste"],
     "recipeInstructions":[{"@type":"HowToStep","text":"Simmer the broth."}],
     "recipeYield":"4"}
    </script></head><body></body></html>
    """

    # Both scraper paths (JSON-LD normalise and HTML extract) end in an LLM
    # call, so the scrape always needs a text/3 expectation.
    defp expect_scrape_normalisation do
      expect(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok,
         %{
           "title" => "Best Miso Ramen",
           "base_servings" => 4,
           "ingredients" => [%{"item" => "miso paste", "quantity" => 2, "unit" => "msk"}],
           "steps" => [
             %{
               "order" => 1,
               "phase" => "COOKING",
               "action" => "Simmer the broth.",
               "ingredients" => ["miso paste"]
             }
           ],
           "tags" => ["japanese"]
         }, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
      end)
    end

    test "is a read tool" do
      assert %{kind: :read} = tool("import_recipe_from_web")
    end

    test "scrapes the chosen url into a web_import proposal" do
      expect(Tore.MockHTTP, :fetch, fn "https://example.com/ramen" -> {:ok, @page_html} end)
      expect_scrape_normalisation()

      args = %{"url" => "https://example.com/ramen"}

      assert {:proposal, %RecipeProposal{} = proposal, %{}, @plan} =
               tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)

      assert proposal.source == :web_import
      assert proposal.source_url == "https://example.com/ramen"
      assert proposal.title =~ "Ramen"
      assert proposal.ingredients != []
    end

    test "carries a pending slot assignment when slot_key is given" do
      expect(Tore.MockHTTP, :fetch, fn _url -> {:ok, @page_html} end)
      expect_scrape_normalisation()

      args = %{"url" => "https://example.com/ramen", "slot_key" => "tue_dinner", "servings" => 2}

      assert {:proposal, _proposal, pending, @plan} =
               tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)

      assert pending == %{slot_key: "tue_dinner", servings: 2}
    end

    test "surfaces a scrape failure as a tool error" do
      expect(Tore.MockHTTP, :fetch, fn _url -> {:error, :timeout} end)

      args = %{"url" => "https://example.com/down"}

      assert {:error, :timeout} =
               tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)
    end

    test "the import writes nothing to the catalog" do
      expect(Tore.MockHTTP, :fetch, fn _url -> {:ok, @page_html} end)
      expect_scrape_normalisation()

      args = %{"url" => "https://example.com/ramen"}

      {:proposal, _proposal, _pending, @plan} =
        tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)

      assert Tore.Recipes.list(home_scope()) == []
    end
  end
end
