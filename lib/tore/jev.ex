defmodule Tore.Jev do
  @moduledoc """
  Jev (`typesafe/jev-1.14`), a decision model on OpenRouter's Decisions API. Given a state, a few
  lines of what's known, it answers typed questions with no text: a `choice` among options, or a
  `noul`, the chance that something holds. Besides pictures it is the one model Tore calls itself
  (2026-11-20), for what sorts things into kinds: which offers a household wants
  (`Tore.Deals.Picks`), how fast each thing in the pantry goes and its picture
  (`Tore.Pantry.Lasts`), and what a new name is (`Tore.Pantry.Learn`); everything else goes
  through pi. It uses
  OpenRouter's key (`:jev_api_key`, from `OPENROUTER_API_KEY`).
  """

  @url "https://openrouter.ai/api/alpha/decisions"
  @model "typesafe/jev-1.14"

  @doc """
  Whether the household may ask Jev: it has an AI sponsor and this month's spend is under the
  limit pi has too. Every call is spent from that budget.
  """
  @spec check(Tore.Scope.t()) :: :ok | {:error, :ai_unavailable | :budget_exceeded}
  def check(%Tore.Scope{} = scope) do
    cond do
      Tore.Household.ai_sponsor(scope) == nil ->
        {:error, :ai_unavailable}

      Tore.Costs.llm_spend_this_month(scope) >= Tore.Pi.monthly_limit_usd() ->
        {:error, :budget_exceeded}

      true ->
        :ok
    end
  end

  @doc """
  The state line that says which language the household's names are in, since Jev guesses at a
  Swedish word it doesn't know ("morot" got salt); nil before the household has chosen one.
  """
  @spec names_language(Tore.Scope.t()) :: String.t() | nil
  def names_language(%Tore.Scope{} = scope) do
    case Tore.Household.locale(scope) do
      "sv" -> "Its names are written in Swedish."
      "en" -> "Its names are written in English."
      nil -> nil
    end
  end

  @doc """
  Asks `questions` (name => question) about `state`, and answers with Jev's answers by name and
  what the call cost in USD. `:req` and `:api_key` stand in for the defaults in tests.
  """
  @spec decide([String.t()], map(), keyword()) :: {:ok, map(), float()} | {:error, term()}
  def decide(state, questions, opts \\ []) when is_list(state) and is_map(questions) do
    key = Keyword.get(opts, :api_key, Application.get_env(:tore, :jev_api_key))
    body = %{model: @model, state: state, questions: questions}

    with {:ok, client} <- client(key),
         {:ok, %OpenRouter.Response{body: %{"answers" => answers} = response}}
         when is_map(answers) <-
           OpenRouter.chat_completions(client, body, Keyword.take(opts, [:req])) do
      {:ok, answers, (get_in(response, ["usage", "cost"]) || 0) / 1}
    else
      {:ok, _no_answers} -> {:error, :invalid_decision}
      {:error, _} = error -> error
    end
  end

  defp client(key) when key in [nil, ""], do: {:error, :no_key}

  defp client(key),
    do:
      OpenRouter.Client.new(
        api_key: key,
        endpoint_url: @url,
        site_url: Application.fetch_env!(:tore, :openrouter_site_url),
        app_name: Application.fetch_env!(:tore, :openrouter_app_name),
        receive_timeout_ms: 60_000
      )
end
