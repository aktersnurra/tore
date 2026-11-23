defmodule Tore.ImageResize do
  @moduledoc """
  Shrinks a picture to a width for the screen it's shown on, as WebP. A generated picture is a
  megabyte or more; a 44px thumbnail needs a few kilobytes.

  The adapter is `:image_resizer` (`Tore.ImageResize.Vips` by default). Callers fall back to the
  original when it fails, so a server without vips still shows every picture, only slower.
  """

  @callback thumbnail(image :: binary(), width :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}

  @spec thumbnail(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def thumbnail(image, width), do: client().thumbnail(image, width)

  defp client, do: Application.get_env(:tore, :image_resizer, Tore.ImageResize.Vips)
end
