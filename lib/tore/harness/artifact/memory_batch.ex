defmodule Tore.Harness.Artifact.MemoryBatch do
  @moduledoc """
  One batch of memory operations for one part, as `Tore.Household.Memory.Ops` takes them, and,
  once applied, what changed: each entry noted, updated or forgotten.
  """

  @behaviour Tore.Harness.Artifact

  @enforce_keys [:target, :operations]
  defstruct [:target, :operations, changes: []]

  @type change :: %{String.t() => String.t()}
  @type t :: %__MODULE__{target: String.t(), operations: [map()], changes: [change()]}

  @impl true
  def kind, do: "MemoryBatch"

  @impl true
  def to_json(%__MODULE__{} = batch),
    do: %{"target" => batch.target, "operations" => batch.operations, "changes" => batch.changes}

  @impl true
  def from_json(%{"target" => target, "operations" => operations, "changes" => changes})
      when is_binary(target) and is_list(operations) and is_list(changes),
      do: %__MODULE__{target: target, operations: operations, changes: changes}
end
