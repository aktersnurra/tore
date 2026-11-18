defmodule Tore.LLM.Spec do
  @moduledoc """
  What answers a one-off model call: `Tore.LLM.Pi`, or `Tore.MockLLM` in tests. Each answer is a
  JSON object, with what it cost.

  Contexts never call a Spec module directly — they go through the
  `Tore.LLM` facade, which dispatches to the configured Spec.
  """

  @type blob :: {:image, binary()} | {:pdf, binary()}
  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cost_usd: number()
        }
  @type opts :: keyword()

  @callback text(system :: String.t(), user :: String.t(), opts()) ::
              {:ok, map(), usage()} | {:error, term()}

  @callback vision(blobs :: [blob()], system :: String.t(), user :: String.t(), opts()) ::
              {:ok, map(), usage()} | {:error, term()}

  @doc """
  Asks typed `questions` about `state`, in the shape of OpenRouter's Decisions API: an answer per
  question, keyed by the question's name.
  """
  @callback decide(state :: [String.t() | map()], questions :: map(), opts()) ::
              {:ok, answers :: map(), usage()} | {:error, term()}
end
