defmodule Tore.LLM.PromptsRecipeIntelligenceTest do
  use ExUnit.Case, async: true

  alias Tore.LLM.Prompts

  describe "generate_recipe_variant/3" do
    @source %{
      title: "Miso Ramen",
      base_servings: 4,
      instructions: "Simmer the broth. Cook the noodles.",
      ingredients: [%{name: "miso paste", quantity: "2", unit: "msk"}]
    }

    test "returns a {system, user} pair carrying source recipe and instruction" do
      {system, user} = Prompts.generate_recipe_variant(@source, "make it vegetarian", nil)

      assert is_binary(system)
      assert user =~ "Miso Ramen"
      assert user =~ "make it vegetarian"
    end

    test "the system prompt carries the shared recipe schema rules" do
      {system, _user} = Prompts.generate_recipe_variant(@source, "simpler", nil)

      assert system =~ "MISE EN PLACE"
      assert system =~ "title is required"
    end

    test "locale is a parameter, not baked into the prompt" do
      {system_none, _} = Prompts.generate_recipe_variant(@source, "simpler", nil)
      {system_sv, _} = Prompts.generate_recipe_variant(@source, "simpler", "sv")

      refute system_none =~ "Swedish"
      assert system_sv =~ "Swedish"
    end
  end
end
