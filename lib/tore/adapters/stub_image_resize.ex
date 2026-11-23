defmodule Tore.Adapters.StubImageResize do
  @moduledoc "Test double for `Tore.ImageResize`: a WebP-headed copy marked with its width, or an error for `\"not an image\"`."
  @behaviour Tore.ImageResize

  @impl true
  def thumbnail("not an image", _width), do: {:error, :not_an_image}
  def thumbnail(image, width), do: {:ok, "RIFF" <> <<0::32>> <> "WEBP" <> "#{width}:" <> image}
end
