defmodule Tore.SpendGuard do
  @monthly_limit_usd 20.0
  # rough haiku pricing, used only for pre-call estimate
  @price_per_token 4.176 / 1_000_000

  # Per-feature defaults. Anything not listed falls back to {50_000, 60}.
  @feature_defaults %{
    suggest_recipe: {6_000, 3},
    recipe_web_search: {10_000, 30},
    recipe_variant: {12_000, 10}
  }

  def allow?(feature, estimated_tokens \\ nil) do
    {default_tokens, cooldown} = Map.get(@feature_defaults, feature, {50_000, 60})
    estimate = estimated_tokens || default_tokens

    with :ok <- budget_ok?(estimate),
         :ok <- cooldown_ok?(feature, cooldown) do
      :ok
    end
  end

  def log_usage(feature, usage) do
    Tore.Costs.log_llm_usage(%{
      feature: to_string(feature),
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: usage.cost_usd
    })

    :ok
  end

  defp budget_ok?(estimated_tokens) do
    spent = Tore.Costs.llm_spend_this_month()

    if spent + estimated_tokens * @price_per_token > @monthly_limit_usd do
      {:error, :budget_exceeded}
    else
      :ok
    end
  end

  defp cooldown_ok?(feature, cooldown_seconds) do
    case Tore.Costs.last_llm_call(feature) do
      nil ->
        :ok

      last ->
        seconds =
          DateTime.diff(DateTime.utc_now(), DateTime.from_naive!(last.inserted_at, "Etc/UTC"))

        if seconds < cooldown_seconds, do: {:error, :cooldown}, else: :ok
    end
  end
end
