defmodule Tore.Harness.Artifact.Registry do
  alias Tore.Harness.Artifact.{
    CostEntry,
    MemoryBatch,
    PantryBeliefUpdate,
    PantrySnapshot,
    PlanDiff,
    RecipeProposal,
    RunBundle,
    RunSummary
  }

  @registry %{
    "CostEntry" => CostEntry,
    "MemoryBatch" => MemoryBatch,
    "PantryBeliefUpdate" => PantryBeliefUpdate,
    "PantrySnapshot" => PantrySnapshot,
    "PlanDiff" => PlanDiff,
    "RecipeProposal" => RecipeProposal,
    "RunBundle" => RunBundle,
    "RunSummary" => RunSummary
  }

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(kind), do: Map.fetch(@registry, kind)

  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@registry)

  @spec modules() :: [module()]
  def modules, do: Map.values(@registry)
end
