defmodule Tore.Harness.Artifact.Registry do
  alias Tore.Harness.Artifact.{
    CostEntry,
    HomePick,
    MemoryBatch,
    PantryBeliefUpdate,
    PlanDiff,
    RecipeEdit,
    RecipeProposal,
    ShopChange
  }

  @registry %{
    "CostEntry" => CostEntry,
    "HomePick" => HomePick,
    "MemoryBatch" => MemoryBatch,
    "PantryBeliefUpdate" => PantryBeliefUpdate,
    "PlanDiff" => PlanDiff,
    "RecipeEdit" => RecipeEdit,
    "RecipeProposal" => RecipeProposal,
    "ShopChange" => ShopChange
  }

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(kind), do: Map.fetch(@registry, kind)
end
