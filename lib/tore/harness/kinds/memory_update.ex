defmodule Tore.Harness.Kinds.MemoryUpdate do
  @moduledoc """
  Capture's `memory` tool: one batch of operations on one part of the household's memory, as the
  model wrote them from what someone said. There is no LLM step in the run; the batch is the
  proposal, submitted with `Runs.submit/4`.

  It verifies and applies as the weekly review does, and undo forgets what it added and brings
  back what it forgot. `ctx` holds the `:batch`.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Artifact.MemoryBatch
  alias Tore.Harness.Kinds.MemoryReview

  @impl true
  def kind, do: "memory_update_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(%{batch: %MemoryBatch{target: target}}),
    do: %{input: %{"target" => target}, actor: :user}

  @impl true
  defdelegate verify(batches, ctx), to: MemoryReview

  @impl true
  defdelegate review_question(batches), to: MemoryReview

  @impl true
  defdelegate apply_proposal(batches, ctx), to: MemoryReview
end
