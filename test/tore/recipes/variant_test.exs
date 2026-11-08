defmodule Tore.Recipes.VariantTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Recipes.Variant

  # Recipes.create/1 fires an async image-generation Task. Left alone it calls
  # MockLLM.text/3 to write an image prompt, racing the expectation each test
  # sets for the variant call itself. Passing :image_url routes that Task to
  # the HTTP client instead, so the only text/3 call is the one under test.
  defp source_recipe do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)

    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Miso Ramen",
        instructions: "Simmer the broth. Cook the noodles.",
        base_servings: 4,
        image_url: "https://example.com/ramen.jpg",
        ingredients: [
          %{name: "miso paste", quantity: Decimal.new("2"), unit: "msk"},
          %{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}
        ]
      })

    recipe
  end

  defp model_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "description" => "Miso ramen without the pork.",
      "base_servings" => 4,
      "prep_time_minutes" => 10,
      "cook_time_minutes" => 20,
      "ingredients" => [
        %{"item" => "miso paste", "quantity" => 2, "unit" => "msk"},
        %{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}
      ],
      "steps" => [
        %{
          "order" => 1,
          "phase" => "MISE EN PLACE",
          "action" => "Cube the tofu.",
          "ingredients" => ["firm tofu"]
        },
        %{
          "order" => 2,
          "phase" => "COOKING",
          "action" => "Simmer the broth.",
          "ingredients" => ["miso paste"]
        }
      ],
      "tags" => ["japanese", "vegetarian"]
    }
  end

  test "build/2 returns a RecipeProposal carrying provenance" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, model_payload(), %{prompt_tokens: 100, completion_tokens: 200, cost_usd: 0.002}}
    end)

    assert {:ok, %RecipeProposal{} = proposal, usage} =
             Variant.build(recipe, "make it vegetarian")

    assert proposal.title == "Vegetarian Miso Ramen"
    assert proposal.source == :generation
    assert proposal.source_recipe_id == recipe.id
    assert proposal.instruction == "make it vegetarian"
    assert proposal.base_servings == 4
    assert usage.completion_tokens == 200
  end

  test "build/2 maps model ingredients into proposal ingredients" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert proposal.ingredients == [
             %{name: "miso paste", quantity: "2", unit: "msk"},
             %{name: "firm tofu", quantity: "300", unit: "g"}
           ]
  end

  test "build/2 flattens the steps into instructions text" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert proposal.instructions =~ "Cube the tofu."
    assert proposal.instructions =~ "Simmer the broth."
  end

  test "build/2 sends the source recipe's ingredients to the model" do
    recipe = source_recipe()
    test_pid = self()

    expect(Tore.MockLLM, :text, fn _system, user, _opts ->
      send(test_pid, {:user_prompt, user})
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, _proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert_received {:user_prompt, user}
    assert user =~ "Miso Ramen"
    assert user =~ "pork belly"
  end

  test "build/2 propagates an LLM error" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Variant.build(recipe, "make it vegetarian")
  end

  test "build/2 rejects a payload with no title" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, %{"ingredients" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:error, :invalid_response} = Variant.build(recipe, "make it vegetarian")
  end
end
