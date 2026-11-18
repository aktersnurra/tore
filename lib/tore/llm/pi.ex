defmodule Tore.LLM.Pi do
  @moduledoc """
  `Tore.LLM.Spec` answered by pi: each call is a one-shot pi session (`Tore.Pi.Session` with
  `oneshot: true`), pi as a plain model with no tools, that ends with its answer. The feature's own
  system prompt goes at the top of the message, since a one-shot's system prompt is
  `harness/ONESHOT.md`. JSON is asked for in words, with the call's schema when it has one, and
  read from pi's reply.

  The `Tore.LLM` facade has already let the household through and records what the answer cost,
  under its feature.
  """
  @behaviour Tore.LLM.Spec

  @timeout :timer.minutes(3)

  @impl true
  def text(system, user, opts), do: answer([system, user, json_instruction(opts)], [], opts)

  @impl true
  def vision(blobs, system, user, opts) do
    if Enum.all?(blobs, &match?({:image, _}, &1)) do
      images = for {:image, bytes} <- blobs, do: {mime(bytes), bytes}
      answer([system, user, json_instruction(opts)], images, opts)
    else
      {:error, :unsupported_blob}
    end
  end

  @doc """
  The decision model's questions, asked of pi: what is true now, then each question with what its
  answer looks like, in the shape the Decisions API answers.
  """
  @impl true
  def decide(state, questions, opts) when is_list(state) and is_map(questions) do
    facts = Enum.map_join(state, "\n", &if(is_binary(&1), do: &1, else: Jason.encode!(&1)))

    message = [
      "Make some decisions for a household's meal-planning app.\n\nWhat is true now:\n" <> facts,
      """
      Answer every question below, keyed by its name. A question of type "choice" is answered as \
      {"choice": <one of its criteria's keys>, "confidence": <0 to 1>}, choosing the criterion \
      that fits best. A question of type "noul" is answered as {"noul": <0 to 1>}, the \
      probability that its instructions describe the household right now.

      Questions:
      #{Jason.encode!(questions)}
      """,
      "Answer with only a JSON object."
    ]

    answer(message, [], opts)
  end

  defp answer(parts, images, opts) do
    scope = Keyword.fetch!(opts, :scope)
    message = parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
    session = "oneshot-#{System.unique_integer([:positive])}"

    with {:ok, %{text: text, cost_usd: cost}} <-
           Tore.Pi.run(scope, session, message,
             oneshot: true,
             images: images,
             timeout: Keyword.get(opts, :timeout, @timeout)
           ),
         {:ok, json} <- json(text) do
      {:ok, json, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: cost}}
    end
  end

  defp json_instruction(opts) do
    case Keyword.get(opts, :response_format) do
      %{json_schema: %{schema: schema}} ->
        "Answer with only a JSON object that matches this JSON Schema:\n" <> Jason.encode!(schema)

      _object ->
        "Answer with only a JSON object."
    end
  end

  # The object in pi's reply, also when a model wraps it in a Markdown fence.
  defp json(nil), do: {:error, :no_content}

  defp json(text) do
    trimmed = String.trim(text)

    candidate =
      case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, trimmed) do
        [_, inner] -> inner
        nil -> trimmed
      end

    case Jason.decode(candidate) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, :invalid_json}
    end
  end

  # pi wants each image's type; Tore's photos are JPEG unless their bytes say otherwise.
  defp mime(<<0x89, "PNG", _::binary>>), do: "image/png"
  defp mime(<<"GIF8", _::binary>>), do: "image/gif"
  defp mime(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp mime(_bytes), do: "image/jpeg"
end
