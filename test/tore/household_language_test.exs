defmodule Tore.HouseholdLanguageTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.{Accounts, Household, Pantry, Prep, Recipes}
  alias Tore.Capture.Dispatch

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  @recipe_html """
  <html><head><script type="application/ld+json">
  {"@type": "Recipe", "name": "Soppa", "recipeIngredient": ["vatten"]}
  </script></head></html>
  """

  setup do
    {:ok, _} = Household.update_household(%{locale: "en"})
    :ok
  end

  test "a new person starts in the household's language" do
    {:ok, {admin, _code}} = Accounts.create_admin("Admin")
    {:ok, {user, _code}} = Accounts.create_user(%{name: "Partner"})

    assert admin.locale == "en"
    assert user.locale == "en"
  end

  test "shelf photos are read into the household's language" do
    expect(Tore.MockLLM, :vision, fn _blobs, _system, user, _opts ->
      assert user =~ "English"
      refute user =~ "Swedish"
      {:ok, %{"items" => []}, @usage}
    end)

    assert {:ok, []} = Pantry.parse_image(<<255, 216, 255>>)
  end

  test "a recipe photo is stored in the household's language" do
    expect(Tore.MockLLM, :vision, fn _blobs, system, _user, _opts ->
      assert system =~ "into English"
      {:ok, %{"title" => "Soup", "ingredients" => [], "steps" => [], "tags" => []}, @usage}
    end)

    assert {:ok, _} = Recipes.extract_from_images([<<255, 216, 255>>])
  end

  test "a recipe link from Capture is stored in the household's language" do
    expect(Tore.MockHTTP, :fetch, fn _url -> {:ok, @recipe_html} end)

    expect(Tore.MockLLM, :text, fn system, _user, _opts ->
      assert system =~ "into English"
      {:ok, %{"title" => "Soup", "ingredients" => [], "steps" => [], "tags" => []}, @usage}
    end)

    assert %{recipe_card: true} = Dispatch.import_recipe_from_url("https://example.com/soup")
  end

  test "a prep guide is written in the household's language" do
    expect(Tore.MockLLM, :text, fn system, _user, _opts ->
      assert system =~ "into English"
      {:error, :timeout}
    end)

    assert {:error, :timeout} = Prep.generate_guide("plan:2026-11-02", ~D[2026-11-02])
  end
end
