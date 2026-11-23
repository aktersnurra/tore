defmodule Tore.Recipes.Pictures do
  @moduledoc """
  A recipe's picture at the widths the screens show it: 256 (thumbnails, up to 80px at 3x),
  720 (cards) and 1440 (the big picture on Today and an open recipe).

  Each width is made from the original once, with `Tore.ImageResize`, and kept beside it as
  `<key>.w<width>.webp`, so the next look is a plain read. A picture's key never changes
  (a new picture is a new key), so neither does a width made from it. Widths are made through
  `Tore.Recipes.Pictures.Maker`: a few at a time, each once however many ask.
  """

  require Logger

  import Ecto.Query

  alias Tore.Recipes.Pictures.Maker
  alias Tore.Recipes.Recipe
  alias Tore.{Repo, Scope, Storage}

  @widths [256, 720, 1440]

  # How long a look waits for its width before it's sent the original instead.
  @wait_ms 15_000

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
  `{:ok, original, :original}` when it couldn't (no vips, a busy queue, say), so the screen still
  has a picture.
  """
  @spec get(String.t(), pos_integer() | nil) ::
          {:ok, binary(), :resized | :original} | {:error, term()}
  def get(key, nil), do: original(key)

  def get(key, width) when width in @widths do
    with {:error, _} <- kept(key, width),
         {:error, _} <- make(key, width, nil, @wait_ms) do
      original(key)
    else
      {:ok, small} -> {:ok, small, :resized}
    end
  end

  @doc """
  Makes every width of a stored picture that isn't kept yet, so its first look is already small.
  `image` is its bytes when the caller has them, saving a read.
  """
  @spec warm(String.t(), binary() | nil) :: :ok
  def warm(key, image \\ nil) do
    for width <- @widths, match?({:error, _}, kept(key, width)) do
      make(key, width, image, :infinity)
    end

    :ok
  end

  @doc """
  Every household's pictures at every width: for the pictures stored before widths were made.
  Run once on the server: `bin/tore rpc "Tore.Recipes.Pictures.warm_all()"`.
  """
  @spec warm_all() :: :ok
  def warm_all do
    for household_id <- Tore.Household.list_ids(),
        key <-
          Repo.all(
            from(r in Recipe, where: not is_nil(r.image_path), select: r.image_path),
            Scope.repo_opts(Scope.for_household(household_id))
          ) do
      warm(key)
    end

    :ok
  end

  defp make(key, width, image, wait) do
    Maker.run({key, width}, fn -> resize_and_keep(key, width, image) end, wait)
  end

  defp resize_and_keep(key, width, image) do
    with {:ok, image} <- if(image, do: {:ok, image}, else: read(key)),
         {:ok, small} <- Tore.ImageResize.thumbnail(image, width) do
      with {:error, reason} <-
             Storage.client().put_object(bucket(), variant_key(key, width), small,
               content_type: "image/webp"
             ) do
        Logger.warning("could not keep #{width}px of #{key}: #{inspect(reason)}")
      end

      {:ok, small}
    else
      {:error, reason} = error ->
        Logger.info("#{key} not resized to #{width}px: #{inspect(reason)}")
        error
    end
  end

  defp kept(key, width), do: read(variant_key(key, width))

  defp original(key) do
    with {:ok, body} <- read(key), do: {:ok, body, :original}
  end

  defp read(key), do: Storage.client().get_object(bucket(), key)

  defp variant_key(key, width), do: "#{key}.w#{width}.webp"

  defp bucket, do: Storage.Buckets.recipes()
end
