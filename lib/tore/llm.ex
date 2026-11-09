defmodule Tore.LLM do
  @moduledoc """
  Facade contexts call. Dispatches to the configured `Tore.LLM.Spec`
  implementation — by default `Tore.LLM.OpenAI`. Callers never see the
  wire shape or the underlying provider.

  Every call is for a household, and this is the one gate in front of OpenRouter: a call is refused
  when no key is configured, nobody sponsors the household (`Tore.Household.ai_sponsor/1`), or the
  household has spent its monthly limit. Each call's cost is recorded for the household here, under
  the `:feature` option (`:other` when none is given), so the limit sees every call.

  `:llm_spec` remains injectable so contexts use a uniform facade while
  `Tore.LLM.OpenAI` owns OpenAI body construction and response decoding.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Scope

  @type blob :: {:image, binary()} | {:pdf, binary()}
  @type usage :: Tore.LLM.Spec.usage()
  @type tool_response :: Tore.LLM.Spec.tool_response()
  @type refusal :: {:error, :ai_unavailable | :budget_exceeded}

  @monthly_limit_usd 20.0

  @doc "What one household may spend in a calendar month, in USD."
  @spec monthly_limit_usd() :: float()
  def monthly_limit_usd, do: @monthly_limit_usd

  @doc "Whether the household may use the server's LLM at all: a key is configured and someone sponsors it."
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{} = scope) do
    key_configured?() and Tore.Household.ai_sponsor(scope) != nil
  end

  @doc "Whether the household may make a call right now: `:ok`, or the refusal a call would get."
  @spec check(Scope.t()) :: :ok | refusal()
  def check(%Scope{} = scope) do
    cond do
      not available?(scope) -> {:error, :ai_unavailable}
      Tore.Costs.llm_spend_this_month(scope) >= @monthly_limit_usd -> {:error, :budget_exceeded}
      true -> :ok
    end
  end

  @doc """
  What to tell someone whose request was refused by the gate, also when a run wrapped the refusal as
  `{:step_failed, reason}`. Nil for any other error, so the caller keeps its own message.
  """
  @spec refusal_text(term()) :: String.t() | nil
  def refusal_text({:step_failed, reason}), do: refusal_text(reason)
  def refusal_text(:ai_unavailable), do: gettext("AI is off for this household.")

  def refusal_text(:budget_exceeded),
    do: gettext("This household has used its AI budget for this month.")

  def refusal_text(_reason), do: nil

  def text(%Scope{} = scope, system, user, opts \\ []),
    do: call(scope, opts, &spec().text(system, user, &1))

  def web_search(%Scope{} = scope, system, user, opts \\ []),
    do: call(scope, opts, &spec().web_search(system, user, &1))

  def vision(%Scope{} = scope, blobs, system, user, opts \\ []),
    do: call(scope, opts, &spec().vision(blobs, system, user, &1))

  def chat(%Scope{} = scope, system, messages, opts \\ []),
    do: call(scope, opts, &spec().chat(system, messages, &1))

  def chat_with_tools(%Scope{} = scope, system, messages, tools, opts),
    do: call(scope, opts, &spec().chat_with_tools(system, messages, tools, &1))

  defp call(scope, opts, request) do
    {feature, opts} = Keyword.pop(opts, :feature, :other)

    with :ok <- check(scope) do
      case request.(opts) do
        {:ok, _result, usage} = ok ->
          record(scope, feature, usage)
          ok

        error ->
          error
      end
    end
  end

  defp record(scope, feature, usage) do
    {:ok, _} =
      Tore.Costs.log_llm_usage(scope, %{
        feature: to_string(feature),
        prompt_tokens: Map.get(usage, :prompt_tokens, 0),
        completion_tokens: Map.get(usage, :completion_tokens, 0),
        cost_usd: usd(Map.get(usage, :cost_usd))
      })
  end

  defp usd(nil), do: 0.0
  defp usd(%Decimal{} = cost), do: Decimal.to_float(cost)
  defp usd(cost) when is_number(cost), do: cost / 1

  defp key_configured? do
    Application.get_env(:tore, :openrouter_api_key) not in [nil, ""]
  end

  defp spec, do: Application.get_env(:tore, :llm_spec, Tore.LLM.OpenAI)
end
