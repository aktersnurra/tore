defmodule Tore.ImageResize do
  @moduledoc """
  Shrinks a picture to a width for the screen it's shown on, as WebP. A generated picture is a
  megabyte or more; a 44px thumbnail needs a few kilobytes.

  The adapter is `:image_resizer` (`Tore.ImageResize.Vips` by default). Callers fall back to the
  original when it fails, so a server without vips still shows every picture, only slower.
  """

  @type format :: :jpeg | :png | :webp | :gif

  @callback thumbnail(image :: binary(), width :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}

  @spec thumbnail(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def thumbnail(image, width), do: client().thumbnail(image, width)

  @doc """
  What a picture's bytes are, by their first bytes: one of the formats a photo comes in, or nil
  for anything else (SVG, PDF, HTML from a page that answered with an error, ...).
  """
  @spec format(binary()) :: format() | nil
  def format(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  def format(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :png
  def format(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: :webp
  def format(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: :gif
  def format(_), do: nil

  @doc "The content type of a format; a picture of unknown bytes is sent as JPEG, as it's stored."
  @spec content_type(format() | nil) :: String.t()
  def content_type(:png), do: "image/png"
  def content_type(:webp), do: "image/webp"
  def content_type(:gif), do: "image/gif"
  def content_type(_), do: "image/jpeg"

  defp client, do: Application.get_env(:tore, :image_resizer, Tore.ImageResize.Vips)
end
