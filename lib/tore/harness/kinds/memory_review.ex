defmodule Tore.Harness.Kinds.MemoryReview do
  @moduledoc """
  The weekly memory review: the LLM reads the memory and six weeks of planning and proposes
  batches of operations, at most one per part. A rejected answer is retried once with the
  rejection. With no planning to read, it makes no call and changes nothing.

  Applying plans each batch again inside the run's transaction, since entries may have changed
  since `verify`; a batch that no longer fits fails the run and changes nothing.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.{Capsules, Runs}
  alias Tore.Harness.Artifact.MemoryBatch
  alias Tore.Harness.Capsules.{RecentHistoryCapsule, RecipeAffinityCapsule}
  alias Tore.Household
  alias Tore.Household.Memory
  alias Tore.Household.Memory.Ops

  @history_capsules [RecentHistoryCapsule, RecipeAffinityCapsule]

  @doc "Cron entry: reviews memory in each household that can make an LLM call."
  @spec review_weekly() :: :ok
  def review_weekly do
    Household.each_scope(fn scope ->
      if Tore.LLM.check(scope) == :ok, do: Runs.start(scope, __MODULE__, %{})
    end)
  end

  @impl true
  def kind, do: "memory_review_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(_ctx), do: %{input: %{}, actor: :system}

  @impl true
  def propose(_run, %{scope: scope}) do
    case Capsules.compose(@history_capsules, %{scope: scope}) do
      "" -> {:ok, []}
      history -> ask(scope, history)
    end
  end

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

  defp ask(scope, history) do
    memory = Memory.snapshot(scope)
    locale = Household.locale(scope)

    with {:ok, batches} <- call(scope, memory, history, locale, nil) do
      case check(scope, batches) do
        :ok -> {:ok, batches}
        {:error, rejection} -> call(scope, memory, history, locale, rejection)
      end
    end
  end

  defp call(scope, memory, history, locale, rejection) do
    {system, user} = Tore.LLM.Prompts.memory_review(memory, history, locale, rejection)

    with {:ok, %{"batches" => raw}, _usage} when is_list(raw) <-
           Tore.LLM.text(scope, system, user, feature: :memory_review) do
      to_batches(raw)
    else
      {:ok, _reply, _usage} -> {:error, :invalid_response}
      {:error, _} = error -> error
    end
  end

  # A batch with no operations asks for nothing, so it is dropped rather than rejected.
  defp to_batches(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn
      %{"target" => _, "operations" => []}, acc ->
        {:cont, acc}

      %{"target" => target, "operations" => ops}, {:ok, acc}
      when is_binary(target) and is_list(ops) ->
        {:cont, {:ok, acc ++ [%MemoryBatch{target: target, operations: ops}]}}

      _other, _acc ->
        {:halt, {:error, :invalid_response}}
    end)
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
