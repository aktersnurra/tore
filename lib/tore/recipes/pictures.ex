defmodule Tore.Recipes.Pictures do
  @moduledoc """
  A recipe's picture at the widths the screens show it: 256 (thumbnails, up to 80px at 3x),
  720 (cards) and 1440 (the big picture on Today and an open recipe).

  Each width is made from the original once, with `Tore.ImageResize`, and kept beside it as
  `<key>.w<width>.webp`, so the next look is a plain read. A picture's key never changes
  (a new picture is a new key), so neither does a width made from it.
  """

  require Logger

  alias Tore.Storage

  @widths [256, 720, 1440]

  @spec widths() :: [pos_integer()]
  def widths, do: @widths

  @doc "The width as asked for in a URL, when it's one Tore makes; otherwise nil (the original)."
  @spec width(term()) :: pos_integer() | nil
  def width(w) when w in @widths, do: w

  def width(w) when is_binary(w) do
    case Integer.parse(w) do
      {n, ""} -> width(n)
      _ -> nil
    end
  end

  def width(_), do: nil

  @doc """
  The picture at `width`: `{:ok, bytes, :resized}` when that width is kept or could be made, and
  `{:ok, original, :original}` when it couldn't (no vips, say), so the screen still has a picture.
  """
  @spec get(String.t(), pos_integer() | nil) ::
          {:ok, binary(), :resized | :original} | {:error, term()}
  def get(key, nil), do: original(key)

  def get(key, width) when width in @widths do
    case Storage.client().get_object(bucket(), variant_key(key, width)) do
      {:ok, body} -> {:ok, body, :resized}
      _ -> make(key, width)
    end
  end

  @doc "Makes every width of a just-stored picture, so its first look is already small."
  @spec warm(String.t(), binary() | nil) :: :ok
  def warm(key, image \\ nil) do
    with {:ok, image, :original} <- if(image, do: {:ok, image, :original}, else: original(key)) do
      Enum.each(@widths, &resize_and_keep(key, image, &1))
    end

    :ok
  end

  defp make(key, width) do
    with {:ok, image, :original} <- original(key) do
      case resize_and_keep(key, image, width) do
        {:ok, small} -> {:ok, small, :resized}
        {:error, _} -> {:ok, image, :original}
      end
    end
  end

  defp resize_and_keep(key, image, width) do
    case Tore.ImageResize.thumbnail(image, width) do
      {:ok, small} ->
        with {:error, reason} <-
               Storage.client().put_object(bucket(), variant_key(key, width), small,
                 content_type: "image/webp"
               ) do
          Logger.warning("could not keep #{width}px of #{key}: #{inspect(reason)}")
        end

        {:ok, small}

      {:error, reason} = error ->
        Logger.info("#{key} not resized to #{width}px: #{inspect(reason)}")
        error
    end
  end

  defp original(key) do
    with {:ok, body} <- Storage.client().get_object(bucket(), key), do: {:ok, body, :original}
  end

  defp variant_key(key, width), do: "#{key}.w#{width}.webp"

  defp bucket, do: Storage.Buckets.recipes()
end
