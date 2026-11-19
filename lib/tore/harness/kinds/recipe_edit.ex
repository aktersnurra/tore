defmodule Tore.Harness.Kinds.RecipeEdit do
  @moduledoc """
  pi changes a saved recipe: a revised version of it (`update_recipe`), or a new picture
  (`draw_recipe_picture`). Submitted whole over MCP; `ctx` holds the `:edit`.

  The revised recipe passes `RecipeProposalVerifier` like a new one, compared with every recipe
  but itself. It applies straight away, and undo puts the recipe back as it was, picture too
  (`Tore.Recipes.snapshot/1`). Recipe screens hear `{:recipe_changed, id}` either way.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Recipes, Scope}
  alias Tore.Harness.Artifact.{RecipeEdit, RecipeProposal}
  alias Tore.Harness.Verifier.RecipeProposalVerifier

  @impl true
  def kind, do: "recipe_edit_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(%{edit: %RecipeEdit{recipe_id: id}}),
    do: %{input: %{"recipe_id" => id}, actor: :user}

  @impl true
  def verify(%RecipeEdit{recipe_id: id} = edit, %{scope: scope}) do
    cond do
      Recipes.get(scope, id) == nil ->
        {:fail, :recipe_not_found, :reject}

      edit.recipe == nil ->
        :ok

      true ->
        edit.recipe
        |> Recipes.attrs_from_parsed()
        |> RecipeProposal.from_attrs(:photo, nil)
        |> RecipeProposalVerifier.verify(%{
          existing_recipes: Recipes.catalog_fingerprints(scope, id)
        })
    end
  end

  @impl true
  def review_question(_edit), do: nil

  @impl true
  def apply_proposal(%RecipeEdit{recipe_id: id} = edit, %{scope: scope}) do
    recipe = Recipes.get!(scope, id)
    # A meal's ingredients are its parts' (`get!` adds them up): undo keeps its own rows, and an
    # edit of the meal leaves them to the parts.
    before = Recipes.snapshot(Recipes.get(scope, id))

    attrs =
      if(edit.recipe, do: Recipes.attrs_from_parsed(edit.recipe), else: %{})
      |> Map.delete(:image_url)
      |> then(&if recipe.parts == [], do: &1, else: Map.delete(&1, :ingredients))
      |> then(&if edit.image_path, do: Map.put(&1, :image_path, edit.image_path), else: &1)

    with {:ok, _recipe} <- Recipes.update(scope, recipe, attrs) do
      {:ok, {:steps, [{:restore_recipe, id, before}]}, [edit]}
    end
  end

  @impl true
  def after_commit(%{status: status, input: %{"recipe_id" => id}} = run)
      when status in [:applied, :reverted] do
    scope = Scope.for_household(run.household_id)
    Phoenix.PubSub.broadcast(Tore.PubSub, Recipes.topic(scope), {:recipe_changed, id})
    :ok
  end

  def after_commit(_run), do: :ok
end
