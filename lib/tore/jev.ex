defmodule Tore.Jev do
  @moduledoc """
  Jev (`typesafe/jev-1.14`), a decision model on OpenRouter's Decisions API. Given a state, a few
  lines of what's known, it answers typed questions with no text: a `choice` among options, or a
  `noul`, the chance that something holds. Besides pictures it is the one model Tore calls itself
  (2026-11-20), to guess which offers a household wants (`Tore.Deals.Picks`) and how fast each
  thing in the pantry goes (`Tore.Pantry.Lasts`); everything else goes through pi. It uses
  OpenRouter's key (`:jev_api_key`, from `OPENROUTER_API_KEY`).
  """

  @url "https://openrouter.ai/api/alpha/decisions"
  @model "typesafe/jev-1.14"

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
