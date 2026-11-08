defmodule Tore.Harness.KitchenMemorySynthesis do
  @moduledoc """
  Pure helpers for `:kitchen_memory_synthesis_run`.

  The Orchestrator drives the Run aggregate; this module owns the
  synthesis-specific bits: composing the events-summary input from declared
  capsules, calling the LLM, building the `MemoryUpdate` artifact, and
  comparing against the current active set to classify added / superseded /
  unchanged.
  """

  alias Tore.Harness.Artifact.MemoryUpdate
  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    ActiveInsightsCapsule,
    RecentHistoryCapsule,
    RecipeAffinityCapsule
  }

  alias Tore.Household
  alias Tore.Harness.Orchestrator

  @capsules [
    ActiveInsightsCapsule,
    RecentHistoryCapsule,
    RecipeAffinityCapsule
  ]

  @max_active 10

  @doc "Cron entry: dispatch the weekly memory synthesis run for every household."
  @spec synthesise_weekly() :: :ok
  def synthesise_weekly do
    Enum.each(Household.list_ids(), &synthesise_for(Tore.Scope.for_household(&1)))
  end

  @spec synthesise_for(Tore.Scope.t()) :: {:ok, term()} | {:error, term()}
  def synthesise_for(%Tore.Scope{} = scope) do
    ctx = %{
      household_id: scope.household_id,
      user_id: nil,
      plan_stream_id: Tore.Streams.plan(scope, Date.utc_today()),
      week_start: Date.utc_today()
    }

    Orchestrator.dispatch(:kitchen_memory_synthesis_run, ctx)
  end

  @spec capsules() :: [module()]
  def capsules, do: @capsules

  @spec max_active() :: pos_integer()
  def max_active, do: @max_active

  @spec events_summary(map()) :: String.t()
  def events_summary(ctx) do
    Capsules.compose(@capsules, ctx)
  end

  @spec synthesise(String.t()) ::
          {:ok,
           [%{kind: String.t(), body: String.t(), confidence: float(), evidence: [integer()]}]}
          | {:error, term()}
  def synthesise(summary) do
    {system, user} = Tore.LLM.Prompts.synthesise_insights(summary)

    case Tore.LLM.text(system, user, []) do
      {:ok, %{"insights" => insights}, _usage} when is_list(insights) ->
        {:ok,
         Enum.map(insights, fn i ->
           %{
             kind: i["kind"],
             body: i["body"],
             confidence: i["confidence"] || 0.5,
             evidence: i["evidence"] || []
           }
         end)}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  @spec build_artifact(Tore.Scope.t(), [map()]) :: MemoryUpdate.t()
  def build_artifact(%Tore.Scope{} = scope, new_insights) do
    active = Household.list_active_insights(scope)
    active_bodies = MapSet.new(active, & &1.body)

    added =
      new_insights
      |> Enum.map(&normalise/1)
      |> Enum.reject(fn ins -> MapSet.member?(active_bodies, ins.body) end)

    new_bodies = MapSet.new(new_insights, fn ins -> ins[:body] || ins["body"] end)

    {unchanged_rows, superseded_rows} =
      Enum.split_with(active, fn row -> MapSet.member?(new_bodies, row.body) end)

    %MemoryUpdate{
      added: added,
      unchanged: Enum.map(unchanged_rows, &row_to_insight/1),
      superseded: Enum.map(superseded_rows, &row_to_insight/1)
    }
  end

  @spec apply!(Tore.Scope.t(), MemoryUpdate.t()) ::
          {:ok, [Household.HouseholdInsight.t()]} | {:error, term()}
  def apply!(%Tore.Scope{} = scope, %MemoryUpdate{added: added, unchanged: unchanged}) do
    # replace_insights/2 tombstones every active row and inserts the given set.
    # Pass added + unchanged so unchanged insights re-land with a fresh
    # generated_at and identity (no in-place update). This is intentional: the
    # synthesis is the authoritative weekly snapshot.
    Household.replace_insights(scope, added ++ unchanged)
  end

  defp normalise(ins) do
    %{
      kind: ins[:kind] || ins["kind"],
      body: ins[:body] || ins["body"],
      confidence: ins[:confidence] || ins["confidence"] || 0.5,
      evidence: ins[:evidence] || ins["evidence"] || []
    }
  end

  defp row_to_insight(row) do
    %{
      kind: row.kind,
      body: row.body,
      confidence: row.confidence,
      evidence: decode_evidence(row.evidence)
    }
  end

  defp decode_evidence(nil), do: []

  defp decode_evidence(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_evidence(list) when is_list(list), do: list
end
