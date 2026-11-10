defmodule Tore.Harness.Kinds.HomePick do
  @moduledoc """
  Picks the screen the app opens on and the quick swaps above the chat box (`Tore.Home`).

  One call to the decision model (`Tore.LLM.decide/4`): a choice among the screens and a yes/no
  per swap, about facts worked out in code. Unsure, or when the call fails for any reason but
  the gate, the run stores the fixed rule's pick, so a stale pick is still replaced. It changes
  nothing else, so its undo is empty.
  """

  @behaviour Tore.Harness.Kind

  require Logger

  alias Tore.Home
  alias Tore.Harness.Artifact.HomePick

  @no_usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}
  @refusals [:ai_unavailable, :budget_exceeded]

  @impl true
  def kind, do: "home_pick_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(_ctx), do: %{input: %{}, actor: :system}

  @doc "`ctx` may hold `:now`, the local time to pick for; it defaults to `Tore.Home.now/0`."
  @impl true
  def propose(_run, %{scope: scope} = ctx) do
    facts = Home.facts(scope, ctx[:now] || Home.now())

    case Tore.LLM.decide(scope, Home.state(scope, facts), Home.questions(facts),
           feature: :home_pick
         ) do
      {:ok, answers, usage} ->
        pick = Home.pick(answers, facts)
        log(scope, pick, answers)
        {:ok, pick, usage}

      {:error, reason} when reason in @refusals ->
        {:error, reason}

      {:error, reason} ->
        Logger.warning(
          "home_pick_unavailable household_id=#{scope.household_id} reason=#{inspect(reason)}"
        )

        {:ok, Home.fallback_pick(facts), @no_usage}
    end
  end

  @impl true
  def verify(%HomePick{screen: screen, swaps: swaps}, _ctx) do
    if screen in Home.screens() and length(swaps) <= Home.max_swaps() and
         swaps == Enum.uniq(swaps) and Enum.all?(swaps, &(&1 in Home.swap_keys())) and
         :"open_#{screen}" not in swaps,
       do: :ok,
       else: {:fail, :invalid_home_pick, :reject}
  end

  @impl true
  def review_question(_pick), do: nil

  @impl true
  def apply_proposal(%HomePick{} = pick, _ctx), do: {:ok, {:steps, []}, [pick]}

  # The probabilities are logged so the confidence threshold can be tuned from real picks.
  defp log(scope, pick, answers) do
    Logger.info(
      "home_pick_decided household_id=#{scope.household_id} screen=#{pick.screen} " <>
        "source=#{pick.source} answers=#{Jason.encode!(answers)}"
    )
  end
end
