defmodule Tore.SpendGuard do
  @moduledoc """
  A check before an expensive call: would its estimate cross the household's monthly limit, and has the
  same feature run too recently? `Tore.LLM` enforces the limit itself and records every call's cost.
  """

  alias Tore.Scope

  # rough haiku pricing, used only for pre-call estimate
  @price_per_token 4.176 / 1_000_000

  # Per-feature defaults. Anything not listed falls back to {50_000, 60}.
  @feature_defaults %{
    suggest_recipe: {6_000, 3},
    recipe_web_search: {10_000, 30},
    recipe_variant: {12_000, 10}
  }

  def allow?(%Scope{} = scope, feature, estimated_tokens \\ nil) do
    {default_tokens, cooldown} = Map.get(@feature_defaults, feature, {50_000, 60})
    estimate = estimated_tokens || default_tokens

    with :ok <- budget_ok?(scope, estimate),
         :ok <- cooldown_ok?(scope, feature, cooldown) do
      :ok
    end
  end

  defp budget_ok?(scope, estimated_tokens) do
    spent = Tore.Costs.llm_spend_this_month(scope)

    if spent + estimated_tokens * @price_per_token > Tore.LLM.monthly_limit_usd() do
      {:error, :budget_exceeded}
    else
      :ok
    end
  end

  defp cooldown_ok?(scope, feature, cooldown_seconds) do
    case Tore.Costs.last_llm_call(scope, feature) do
      nil ->
        :ok

      last ->
        seconds =
          DateTime.diff(DateTime.utc_now(), DateTime.from_naive!(last.inserted_at, "Etc/UTC"))

        if seconds < cooldown_seconds, do: {:error, :cooldown}, else: :ok
    end
  end
end
