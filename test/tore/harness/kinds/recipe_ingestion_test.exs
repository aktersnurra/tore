defmodule Tore.Harness.Kinds.RecipeIngestionTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Recipes
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.RecipeIngestion

  setup :verify_on_exit!

  @soup %{
    "title" => "Morotssoppa",
    "base_servings" => 4,
    "ingredients" => [%{"item" => "morot", "quantity" => 6, "unit" => "st"}],
    "steps" => [%{"order" => 1, "phase" => "COOKING", "action" => "Koka.", "ingredients" => []}],
    "tags" => []
  }

  setup do
    test_pid = self()

    # Nothing from the page is fetched: report it if it is.
    stub(Tore.MockHTTP, :fetch, fn url ->
      send(test_pid, {:fetched, url})
      {:error, :not_found}
    end)

    %{ctx: capture_ctx(home_scope().household_id, user_fixture().id)}
  end

  defp titles, do: home_scope() |> Recipes.list() |> Enum.map(& &1.title)

  # A recipe pi read from a page or photos and saved, as save_recipe submits it.
  defp from_photo(ctx, recipe \\ @soup) do
    proposal = recipe |> Recipes.attrs_from_parsed() |> RecipeProposal.from_attrs(:photo, nil)
    {:ok, run} = Runs.submit(ctx.scope, RecipeIngestion, proposal, %{proposal: proposal})
    run
  end

  test "a recipe photo is saved straight away, and undo deletes it", %{ctx: ctx} do
    %KitchenRun{id: id} = from_photo(ctx)

    assert %KitchenRun{
             status: :applied,
             kind: "recipe_ingestion_run",
             input: %{"source" => "submitted"},
             artifacts: [%RecipeProposal{source: :photo}]
           } = Runs.get(home_scope(), id)

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
    %KitchenRun{id: id} = from_photo(ctx, raw)

    assert %KitchenRun{status: :applied, artifacts: [proposal]} = Runs.get(home_scope(), id)
    assert %RecipeProposal{base_servings: 4, image_url: nil} = proposal
  end

  describe "a saved recipe's picture" do
    import Tore.FakePi
    setup :fake_pi

    test "is drawn by pi in the house style, not taken from the page", %{
      ctx: ctx,
      pi_log: log
    } do
      linked = Map.put(@soup, "image_url", "https://example.com/soppa.jpg")
      %KitchenRun{status: :applied} = from_photo(ctx, linked)

      [recipe] = Recipes.list(home_scope())
      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))["message"]
      assert prompt =~ "Background job: finish_recipe."
      assert prompt =~ "Recipe #{recipe.id}."
      refute_received {:fetched, _}
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
        }
      )

    assert %KitchenRun{status: :failed, failure_code: :near_duplicate} = from_photo(ctx)
    assert titles() == ["Morotssoppa"]
  end

  test "an imported recipe goes in its collection: buns are baking", %{ctx: ctx} do
    baking = @soup |> Map.put("title", "Kanelbullar") |> Map.put("recipe_type", "baking")
    %KitchenRun{status: :applied} = from_photo(ctx, baking)

    assert [%{title: "Kanelbullar", recipe_type: :baking}] = Recipes.list(home_scope())
  end
end
