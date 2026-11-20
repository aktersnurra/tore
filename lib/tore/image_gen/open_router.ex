defmodule Tore.ImageGen.OpenRouter do
  @moduledoc """
  OpenRouter-backed implementation of `Tore.ImageGen`. What a call cost is OpenRouter's own
  figure, `usage.cost` in its answer.
  """

  @behaviour Tore.ImageGen

  alias OpenRouter.Client

  @impl true
  def generate_food_image(prompt), do: generate_food_image(prompt, [])

  def generate_food_image(prompt, opts) when is_binary(prompt) and is_list(opts) do
    body = %{
      model: image_model(),
      modalities: ["image"],
      messages: [%{role: "user", content: prompt}]
    }

    with {:ok, client} <- client(),
         {:ok, %OpenRouter.Response{body: response_body}} <-
           OpenRouter.chat_completions(client, body, opts) do
      with {:ok, image} <- decode_image(response_body),
           do:
             {:ok, %{image: image, cost_usd: (get_in(response_body, ["usage", "cost"]) || 0) / 1}}
    end
  end

  defp decode_image(resp) do
    data_url =
      get_in(resp, [
        "choices",
        Access.at(0),
        "message",
        "images",
        Access.at(0),
        "image_url",
        "url"
      ])

    case data_url do
      "data:" <> _ ->
        [_prefix, encoded] = String.split(data_url, ",", parts: 2)
        {:ok, Base.decode64!(encoded)}

      nil ->
        {:error, :no_image_returned}
    end
  end

  # The key is optional (`OPENROUTER_API_KEY`): without it there are no pictures.
  defp client do
    case Application.get_env(:tore, :openrouter_api_key) do
      key when key in [nil, ""] ->
        {:error, :no_image_key}

      key ->
        Client.new(
          api_key: key,
          site_url: Application.fetch_env!(:tore, :openrouter_site_url),
          app_name: Application.fetch_env!(:tore, :openrouter_app_name)
        )
    end
  end

  defp image_model,
    do: Application.get_env(:tore, :openrouter_image_model, "black-forest-labs/flux.2-pro")
end
