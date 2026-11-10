defmodule Tore.LLM.OpenAI do
  @moduledoc """
  OpenAI-flavoured wire spec implementation of `Tore.LLM.Spec`.

  Builds OpenAI `chat/completions` bodies, sends them through the shared
  OpenRouter client, and decodes responses locally.
  """

  @behaviour Tore.LLM.Spec

  alias OpenRouter.Client

  @impl true
  def text(system, user, opts) do
    body = %{
      model: Keyword.get(opts, :model, model()),
      response_format: Keyword.get(opts, :response_format, %{type: "json_object"}),
      stream: false,
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ]
    }

    body
    |> chat_completions(opts)
    |> decode_json()
  end

  @impl true
  def web_search(system, user, opts) do
    system
    |> web_search_body(user, opts)
    |> chat_completions(opts)
    |> decode_json()
  end

  # OpenRouter treats web search as a body-level plugin, so no client change
  # is needed — this is `text/3`'s body plus one key.
  @doc false
  def web_search_body(system, user, opts) do
    %{
      model: Keyword.get(opts, :model, model()),
      response_format: Keyword.get(opts, :response_format, %{type: "json_object"}),
      stream: false,
      plugins: [%{id: "web", max_results: Keyword.get(opts, :max_results, 5)}],
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ]
    }
  end

  @impl true
  def vision(blobs, system, user, opts) when is_list(blobs) do
    body = %{
      model: Keyword.get(opts, :model, vision_model()),
      response_format: Keyword.get(opts, :response_format, %{type: "json_object"}),
      stream: false,
      messages: [
        %{role: "system", content: system},
        %{
          role: "user",
          content: [%{type: "text", text: user} | Enum.map(blobs, &blob_to_part/1)]
        }
      ]
    }

    body
    |> chat_completions(opts)
    |> decode_json()
  end

  @impl true
  def chat(system, messages, opts) do
    body = %{
      model: Keyword.get(opts, :model, model()),
      stream: false,
      messages: [%{role: "system", content: system} | messages]
    }

    body
    |> chat_completions(opts)
    |> case do
      {:ok, resp} ->
        content = get_in(resp, ["choices", Access.at(0), "message", "content"])
        {:ok, content, extract_usage(resp)}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def chat_with_tools(system, messages, tools, opts) do
    body =
      %{
        model: Keyword.get(opts, :model, model()),
        stream: false,
        messages: [%{role: "system", content: system} | messages],
        tools: tools
      }
      |> maybe_put_tool_choice(tools, opts)

    case chat_completions(body, opts) do
      {:ok, resp} ->
        msg = get_in(resp, ["choices", Access.at(0), "message"]) || %{}
        usage = extract_usage(resp)

        case msg do
          %{"tool_calls" => calls} when is_list(calls) and calls != [] ->
            {:ok, {:tool_calls, Enum.map(calls, &decode_tool_call/1)}, usage}

          %{"content" => content} when is_binary(content) ->
            {:ok, {:message, content}, usage}

          _ ->
            {:error, {:unexpected_message, msg}}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def decide(state, questions, opts) when is_list(state) and is_map(questions) do
    body = %{
      model: Keyword.get(opts, :model, decisions_model()),
      state: state,
      questions: questions
    }

    with {:ok, %OpenRouter.Response{body: response}} <-
           OpenRouter.chat_completions(client(decisions_url()), body, opts) do
      case response do
        %{"answers" => answers} when is_map(answers) -> {:ok, answers, extract_usage(response)}
        _other -> {:error, :invalid_decision}
      end
    end
  end

  # ---- Private decoding ---------------------------------------------------

  defp decode_json({:ok, resp}) do
    content = get_in(resp, ["choices", Access.at(0), "message", "content"])
    usage = extract_usage(resp)

    case decode_content(content) do
      {:ok, parsed} -> {:ok, parsed, usage}
      {:error, _} = err -> err
    end
  end

  defp decode_json({:error, _} = err), do: err

  defp decode_content(content) when is_binary(content), do: Jason.decode(content)
  defp decode_content(content) when is_map(content) or is_list(content), do: {:ok, content}
  defp decode_content(_), do: {:error, :no_content}

  # Chat reports prompt and completion tokens; the Decisions API, input and output tokens.
  defp extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      cost_usd: usage["cost"] || 0.0
    }
  end

  defp extract_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0.0}

  defp blob_to_part({:image, bin}) do
    %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,#{Base.encode64(bin)}"}}
  end

  defp blob_to_part({:pdf, bin}) do
    %{
      type: "file",
      file: %{filename: "doc.pdf", file_data: "data:application/pdf;base64,#{Base.encode64(bin)}"}
    }
  end

  defp maybe_put_tool_choice(body, [], _opts), do: body

  defp maybe_put_tool_choice(body, _tools, opts) do
    Map.put(body, :tool_choice, Keyword.get(opts, :tool_choice, "auto"))
  end

  defp decode_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => raw_args}}) do
    args =
      case Jason.decode(raw_args || "{}") do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    %{id: id, name: name, args: args}
  end

  defp decode_tool_call(other) when is_map(other) do
    %{
      id: Map.get(other, "id", ""),
      name: get_in(other, ["function", "name"]) || "",
      args: %{}
    }
  end

  # ---- Shared OpenRouter client ------------------------------------------

  defp chat_completions(body, opts) do
    with {:ok, %OpenRouter.Response{body: response_body}} <-
           OpenRouter.chat_completions(client(), body, opts) do
      {:ok, response_body}
    end
  end

  # The Decisions API takes the same key and attribution headers as chat completions, at its own URL.
  defp client(endpoint_url \\ nil) do
    {:ok, client} =
      Client.new(
        [
          api_key: Application.fetch_env!(:tore, :openrouter_api_key),
          site_url: Application.fetch_env!(:tore, :openrouter_site_url),
          app_name: Application.fetch_env!(:tore, :openrouter_app_name)
        ] ++ if(endpoint_url, do: [endpoint_url: endpoint_url], else: [])
      )

    client
  end

  defp model, do: Application.get_env(:tore, :openrouter_model, "openai/gpt-5-mini")

  defp decisions_model, do: Application.get_env(:tore, :decisions_model, "typesafe/jev-1.14")

  defp decisions_url,
    do: Application.get_env(:tore, :decisions_url, "https://openrouter.ai/api/alpha/decisions")

  defp vision_model,
    do: Application.get_env(:tore, :openrouter_vision_model, "google/gemini-3.1-flash-lite")
end
