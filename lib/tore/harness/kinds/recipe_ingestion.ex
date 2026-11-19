defmodule Tore.Harness.Kinds.RecipeIngestion do
  @moduledoc """
  A recipe pi read from a page or photos and submitted whole over MCP (`save_recipe`), as a
  `RecipeProposal`. `ctx` holds the `:proposal`.

  It saves straight away, and undo deletes it. Verifying, saving and the picture work as for a
  recipe the planner proposes.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.Planner

  @impl true
  def kind, do: "recipe_ingestion_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(%{proposal: %RecipeProposal{source_url: url}}),
    do: %{input: %{"source" => "submitted", "url" => url}, actor: :user}

  @impl true
  defdelegate verify(proposal, ctx), to: Planner

  @impl true
  defdelegate review_question(proposal), to: Planner

  @impl true
  defdelegate apply_proposal(proposal, ctx), to: Planner

  @impl true
  defdelegate after_commit(run), to: Planner
end
