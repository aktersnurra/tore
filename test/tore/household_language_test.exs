defmodule Tore.HouseholdLanguageTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.{Prep, Repo}
  alias Tore.Capture.Dispatch

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  @recipe_html """
  <html><head><script type="application/ld+json">
  {"@type": "Recipe", "name": "Soppa", "recipeIngredient": ["vatten"]}
  </script></head></html>
  """

  setup do
    # Straight to the column: a household's language can't change once picked.
    home_household() |> Ecto.Changeset.change(locale: "en") |> Repo.update!()
    :ok
  end

  test "a new person starts in the household's language" do
    assert user_fixture().locale == "en"
  end

  test "a recipe link from Capture is stored in the household's language" do
    expect(Tore.MockHTTP, :fetch, fn _url -> {:ok, @recipe_html} end)

    expect(Tore.MockLLM, :text, fn system, _user, _opts ->
      assert system =~ "into English"

      {:ok,
       %{
         "title" => "Soup",
         "base_servings" => 4,
         "ingredients" => [%{"item" => "water", "quantity" => 1, "unit" => "l"}],
         "steps" => [
           %{"order" => 1, "phase" => "COOKING", "action" => "Boil.", "ingredients" => []}
         ],
         "tags" => []
       }, @usage}
    end)

    assert %{run_stream_id: _, text: text} =
             Dispatch.import_recipe_from_url(
               "https://example.com/soup",
               capture_ctx(home_scope().household_id)
             )

    assert text =~ "Soup"
  end

  test "a prep guide is written in the household's language" do
    expect(Tore.MockLLM, :text, fn system, _user, _opts ->
      assert system =~ "into English"
      {:error, :timeout}
    end)

    assert {:error, :timeout} =
             Prep.generate_guide(
               home_scope(),
               Tore.Streams.plan(home_scope(), ~D[2026-11-02]),
               ~D[2026-11-02]
             )
  end
end
