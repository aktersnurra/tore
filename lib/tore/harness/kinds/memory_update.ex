defmodule Tore.Harness.Kinds.MemoryUpdate do
  @moduledoc """
  A write to the household's memory: one batch of operations on one part, as the model wrote them
  from what someone said or from a week of planning. There is no LLM step in the run; the batch is
  the proposal, submitted with `Runs.submit/4`.

  Applying plans each batch again inside the run's transaction, since entries may have changed
  since `verify`; a batch that no longer fits fails the run and changes nothing. Undo forgets what
  it added and brings back what it forgot. `ctx` holds the `:batch`.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Artifact.MemoryBatch
  alias Tore.Household.Memory
  alias Tore.Household.Memory.Ops

  @impl true
  def kind, do: "memory_update_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(%{batch: %MemoryBatch{target: target}}),
    do: %{input: %{"target" => target}, actor: :user}

  @impl true
  def verify(batches, %{scope: scope}) do
    case check(scope, batches) do
      :ok -> :ok
      {:error, _rejection} -> {:fail, :memory_rejected, :reject}
    end
  end

  @impl true
  def review_question(_batches), do: nil

  @impl true
  def apply_proposal(batches, %{scope: scope, run: run}) do
    batches
    |> Enum.reduce_while({:ok, [], [], []}, fn batch, {:ok, added, forgotten, applied} ->
      case Ops.plan(batch.target, entries(scope, batch.target), batch.operations) do
        {:ok, plan} ->
          written = Memory.write(scope, batch.target, plan, run.id)

          {:cont,
           {:ok, added ++ written.added, forgotten ++ written.forgotten,
            applied ++ [%{batch | changes: written.changes}]}}

        {:error, _rejection} ->
          {:halt, {:fail, :memory_rejected, :reject}}
      end
    end)
    |> case do
      {:ok, [], [], applied} ->
        {:ok, {:steps, []}, applied}

      {:ok, added, forgotten, applied} ->
        {:ok, {:steps, [{:restore_memory, added, forgotten}]}, applied}

      {:fail, _code, _repair} = fail ->
        fail
    end
  end

  @doc """
  `:ok` when `batches` fit the memory as it is now, or the rejection to hand back to the model:
  the error, the current entries and usage, and what was closest.
  """
  @spec check(Tore.Scope.t(), [MemoryBatch.t()]) :: :ok | {:error, map()}
  def check(scope, batches) do
    targets = Enum.map(batches, & &1.target)

    if targets != Enum.uniq(targets) do
      {:error, %{"success" => false, "error" => "send at most one batch per part"}}
    else
      Enum.reduce_while(batches, :ok, fn batch, :ok ->
        case Ops.plan(batch.target, entries(scope, batch.target), batch.operations) do
          {:ok, _plan} -> {:cont, :ok}
          {:error, rejection} -> {:halt, {:error, Map.put(rejection, "target", batch.target)}}
        end
      end)
    end
  end

  defp entries(scope, target),
    do: scope |> Memory.list(target) |> Enum.map(&Map.take(&1, [:id, :text]))
end
