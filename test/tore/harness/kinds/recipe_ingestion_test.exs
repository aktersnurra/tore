defmodule Tore.Harness.Kinds.RecipeIngestionTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Recipes
  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal

  setup :verify_on_exit!

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  @soup %{
    "title" => "Morotssoppa",
    "base_servings" => 4,
    "ingredients" => [%{"item" => "morot", "quantity" => 6, "unit" => "st"}],
    "steps" => [%{"order" => 1, "phase" => "COOKING", "action" => "Koka.", "ingredients" => []}],
    "tags" => []
  }

  setup do
    test_pid = self()

    # The picture made after confirming: report the fetch, and let generating it fail quietly.
    stub(Tore.MockHTTP, :fetch, fn url ->
      send(test_pid, {:fetched, url})
      {:error, :not_found}
    end)

    stub(Tore.MockLLM, :text, fn _, _, _ -> {:error, :ai_unavailable} end)

    %{ctx: %{household_id: home_scope().household_id, user_id: user_fixture().id}}
  end

  defp titles, do: home_scope() |> Recipes.list() |> Enum.map(& &1.title)

  test "a recipe photo waits for review, and confirming saves it until undone", %{ctx: ctx} do
    expect(Tore.MockLLM, :vision, fn _, _, _, _ -> {:ok, @soup, @usage} end)

    bubble = Dispatch.ingest_recipe([<<255, 216, 255>>], ctx)

    assert %{review_link: true, stream_id: id} = bubble
    assert bubble.text =~ "Morotssoppa"
    assert titles() == []

    assert %KitchenRun{
             status: :needs_user,
             kind: "recipe_ingestion_run",
             input: %{"source" => "photo", "pages" => 1},
             artifacts: [%RecipeProposal{source: :photo} = proposal]
           } = Runs.get(home_scope(), id)

    {:ok, %KitchenRun{status: :applied}} = Runs.confirm(home_scope(), id, proposal)
    assert [recipe] = Recipes.list(home_scope())
    assert recipe.title == "Morotssoppa"
    assert [%{"action" => "Koka."}] = Tore.Recipes.Recipe.decode_steps(recipe)

    {:ok, _} = Runs.revert(home_scope(), id)
    assert titles() == []
  end

  test "a photo with no servings is taken to serve 4, and its picture isn't fetched", %{
    ctx: ctx
  } do
    raw = @soup |> Map.put("base_servings", nil) |> Map.put("image_url", "https://evil.example/x")
    expect(Tore.MockLLM, :vision, fn _, _, _, _ -> {:ok, raw, @usage} end)

    %{stream_id: id} = Dispatch.ingest_recipe([<<255, 216, 255>>], ctx)

    assert %KitchenRun{status: :needs_user, artifacts: [proposal]} = Runs.get(home_scope(), id)
    assert %RecipeProposal{base_servings: 4, image_url: nil} = proposal
  end

  test "a linked recipe keeps the page's picture", %{ctx: ctx} do
    Tore.Storage.Mock.reset()

    page = """
    <html><head><script type="application/ld+json">
    {"@type": "Recipe", "name": "Morotssoppa", "image": "https://example.com/soppa.jpg",
     "recipeYield": "4", "recipeIngredient": ["6 morötter"], "recipeInstructions": ["Koka."]}
    </script></head></html>
    """

    test_pid = self()

    stub(Tore.MockHTTP, :fetch, fn
      "https://example.com/soppa" ->
        {:ok, page}

      "https://example.com/soppa.jpg" ->
        send(test_pid, :picture_fetched)
        {:ok, <<255, 216, 255, 0>>}
    end)

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, Map.put(@soup, "image_url", "https://example.com/soppa.jpg"), @usage}
    end)

    %{stream_id: id} = Dispatch.import_recipe_from_url("https://example.com/soppa", ctx)

    assert %KitchenRun{artifacts: [%RecipeProposal{} = proposal]} = Runs.get(home_scope(), id)
    assert proposal.source_url == "https://example.com/soppa"
    assert proposal.image_url == "https://example.com/soppa.jpg"

    {:ok, _} = Runs.confirm(home_scope(), id, proposal)
    assert_receive :picture_fetched, 1000
    [recipe] = Recipes.list(home_scope())
    assert eventually(fn -> Recipes.get(home_scope(), recipe.id).image_path end)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      value = fun.() -> value
      tries == 0 -> nil
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "a recipe already in the catalogue is refused", %{ctx: ctx} do
    {:ok, _} =
      Recipes.create(
        home_scope(),
        %{
          title: "Morotssoppa",
          base_servings: 4,
          ingredients: [%{name: "morot", quantity: Decimal.new(6), unit: "st"}]
        },
        image: false
      )

    expect(Tore.MockLLM, :vision, fn _, _, _, _ -> {:ok, @soup, @usage} end)

    Gettext.put_locale(ToreWeb.Gettext, "sv")
    bubble = Dispatch.ingest_recipe([<<255, 216, 255>>], ctx)

    assert bubble.text =~ "redan har"
    refute Map.has_key?(bubble, :review_link)
    assert titles() == ["Morotssoppa"]
  end

  test "a page that isn't a recipe says so", %{ctx: ctx} do
    expect(Tore.MockHTTP, :fetch, fn _ -> {:ok, "<html><body>Hej</body></html>"} end)
    expect(Tore.MockLLM, :text, fn _, _, _ -> {:ok, %{"not_a_recipe" => true}, @usage} end)

    Gettext.put_locale(ToreWeb.Gettext, "sv")
    bubble = Dispatch.import_recipe_from_url("https://example.com/hej", ctx)

    assert bubble.text =~ "inte ut som ett recept"
    refute Map.has_key?(bubble, :review_link)
    assert titles() == []
  end
end
