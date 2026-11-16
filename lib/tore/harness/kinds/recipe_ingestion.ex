defmodule Tore.Harness.Kinds.RecipeIngestion do
  @moduledoc """
  A recipe someone sends Capture, as photos of its pages or as a link. The model reads it into a
  `RecipeProposal`, which always waits for review: nothing is saved until someone confirms it.
  `ctx` holds `:images` (the page photos) or `:url`, or the `:proposal` itself when it was read
  elsewhere (MCP).

  Confirming saves the recipe, and undo deletes it. Review, saving and the picture work as for a
  recipe the planner proposes.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Recipes
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.Planner

  @impl true
  def kind, do: "recipe_ingestion_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(%{images: images}),
    do: %{input: %{"source" => "photo", "pages" => length(images)}, actor: :user}

  def open(%{url: url}), do: %{input: %{"source" => "web_import", "url" => url}, actor: :user}

  # Read elsewhere and submitted whole, by someone's own Claude over MCP.
  def open(%{proposal: %RecipeProposal{source_url: url}}),
    do: %{input: %{"source" => "submitted", "url" => url}, actor: :user}

  # The recipe calls record their own usage in llm_usage.
  @impl true
  def propose(_run, %{scope: scope, images: images}) do
    with {:ok, attrs} <- Recipes.extract_from_images(scope, images),
         do: {:ok, RecipeProposal.from_attrs(attrs, :photo, nil)}
  end

  def propose(_run, %{scope: scope, url: url}) do
    with {:ok, attrs} <- Recipes.scrape_attrs_from_url(scope, url),
         do: {:ok, RecipeProposal.from_attrs(attrs, :web_import, url)}
  end

  @impl true
  defdelegate verify(proposal, ctx), to: Planner

  @impl true
  defdelegate review_question(proposal), to: Planner

  @impl true
  defdelegate apply_proposal(proposal, ctx), to: Planner

  @impl true
  defdelegate after_commit(run), to: Planner
end
