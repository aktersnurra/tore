defmodule Tore.Harness.Kinds do
  @moduledoc "Finds a kind's module from the name stored on its runs."

  # Tests add kinds of their own through config.
  @modules [
             Tore.Harness.Kinds.MemoryReview,
             Tore.Harness.Kinds.PantryUpdate,
             Tore.Harness.Kinds.PlannerCommand,
             Tore.Harness.Kinds.Receipt,
             Tore.Harness.Kinds.SetPlanSlot,
             Tore.Harness.Kinds.WeeklyPlanning
           ] ++
             Application.compile_env(:tore, :extra_run_kinds, [])

  @spec fetch!(String.t()) :: module()
  def fetch!(kind) when is_binary(kind) do
    Enum.find(@modules, &(&1.kind() == kind)) ||
      raise ArgumentError, "no run kind #{inspect(kind)}"
  end
end
