defmodule Tore.Adapters.StubImageResize do
  @moduledoc "Test double for `Tore.ImageResize`: a WebP-headed copy marked with its width; an error for
  `\"not an image\"`, two seconds for anything starting `\"slow\"`."
  @behaviour Tore.ImageResize

  @impl true
  def available?, do: Application.get_env(:tore, :stub_image_resize_available?, true)

  @impl true
  def thumbnail("not an image", _width), do: {:error, :not_an_image}

  def thumbnail("slow" <> _ = image, width) do
    Process.sleep(2_000)
    {:ok, "RIFF" <> <<0::32>> <> "WEBP" <> "#{width}:" <> image}
  end

  def thumbnail(image, width), do: {:ok, "RIFF" <> <<0::32>> <> "WEBP" <> "#{width}:" <> image}
end
