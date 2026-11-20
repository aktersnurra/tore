defmodule Tore.ImageGen.OpenRouterTest do
  use ExUnit.Case, async: false

  import Req.Test, only: [raw_body: 1, stub: 2]

  alias Tore.ImageGen.OpenRouter

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_config =
      Map.new([:openrouter_api_key, :openrouter_site_url, :openrouter_app_name], fn key ->
        {key, Application.get_env(:tore, key)}
      end)

    Application.put_env(:tore, :openrouter_api_key, "test-key")
    Application.put_env(:tore, :openrouter_site_url, "https://tore.test")
    Application.put_env(:tore, :openrouter_app_name, "Tore Test")

    on_exit(fn ->
      Enum.each(previous_config, fn
        {key, nil} -> Application.delete_env(:tore, key)
        {key, value} -> Application.put_env(:tore, key, value)
      end)
    end)

    %{req: Req.new(plug: {Req.Test, __MODULE__})}
  end

  test "unwraps an OpenRouter response envelope and decodes image bytes from a data URL", %{
    req: req
  } do
    image_bytes = <<137, 80, 78, 71>>

    stub(__MODULE__, fn conn ->
      assert %{
               "model" => "black-forest-labs/flux.2-pro",
               "modalities" => ["image"],
               "messages" => [%{"role" => "user", "content" => "A plated meal"}]
             } = raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "images" => [
                %{
                  "image_url" => %{
                    "url" => "data:image/png;base64,#{Base.encode64(image_bytes)}"
                  }
                }
              ]
            }
          }
        ]
      })
    end)

    assert {:ok, ^image_bytes} = OpenRouter.generate_food_image("A plated meal", req: req)
  end
end
