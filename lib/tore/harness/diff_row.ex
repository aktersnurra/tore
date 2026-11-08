defmodule Tore.Harness.DiffRow do
  @moduledoc """
  One line in a run receipt — the cross-surface render shape derived from a
  run's typed artifacts (PlanDiff, PantryBeliefUpdate, …). `op` is the
  docs/specs/ui.md §16.4 prefix alphabet: `+` `-` `~` `?` mapped to `:added`,
  `:removed`, `:changed`, `:assumed`.

  DiffRow is render-time only. The canonical record stays in the typed
  artifact on the Run event stream; rebuilding rows is cheap.
  """

  @ops [:added, :removed, :changed, :assumed]
  @surfaces [:plan, :shop, :pantry, :recipe, :prep, :cost]

  @enforce_keys [:op, :surface, :label]
  defstruct [:op, :surface, :label, :before, :after, :reason]

  @type t :: %__MODULE__{
          op: atom(),
          surface: atom(),
          label: String.t(),
          before: any(),
          after: any(),
          reason: String.t() | nil
        }

  def ops, do: @ops
  def surfaces, do: @surfaces
end
