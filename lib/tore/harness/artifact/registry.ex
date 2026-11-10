defmodule Tore.Harness.Artifact.Registry do
  alias Tore.Harness.Artifact.{
    CostEntry,
    HomePick,
    MemoryBatch,
    PantryBeliefUpdate,
    PlanDiff,
    RecipeProposal,
    ShopChange
  }

  @registry %{
    "CostEntry" => CostEntry,
    "HomePick" => HomePick,
    "MemoryBatch" => MemoryBatch,
    "PantryBeliefUpdate" => PantryBeliefUpdate,
    "PlanDiff" => PlanDiff,
    "RecipeProposal" => RecipeProposal,
    "ShopChange" => ShopChange
  }

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(kind), do: Map.fetch(@registry, kind)

  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@registry)

  @spec modules() :: [module()]
  def modules, do: Map.values(@registry)
end
