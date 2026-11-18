defmodule Tore.Harness.Kinds.RecipeIngestion do
  @moduledoc """
  A recipe from a link, read by the model into a `RecipeProposal`, or one pi read from a page or
  photos and submitted whole over MCP (`save_recipe`). `ctx` holds `:url` or the `:proposal`.

  It saves straight away, and undo deletes it. Verifying, saving and the picture work as for a
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
  def open(%{url: url}), do: %{input: %{"source" => "web_import", "url" => url}, actor: :user}

  # Read elsewhere and submitted whole, by someone's own Claude over MCP.
  def open(%{proposal: %RecipeProposal{source_url: url}}),
    do: %{input: %{"source" => "submitted", "url" => url}, actor: :user}

  # The recipe calls record their own usage in llm_usage.
  @impl true
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
