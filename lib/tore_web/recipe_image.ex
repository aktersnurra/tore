defmodule ToreWeb.RecipeImage do
  @moduledoc """
  Where a recipe's picture is served, and the version that makes it cacheable.

  Each picture is stored under its own key (a new UUID every time one is drawn or fetched), so a
  hash of the key names that exact picture: it goes in the URL as `?v=` and is the response's
  ETag. A URL with the current version never changes, so the browser keeps it for a year without
  asking again; a new picture is a new URL.
  """

  use ToreWeb, :verified_routes

  @type recipe :: %{id: integer(), image_path: String.t() | nil}

  @doc """
  The picture's URL, versioned by its key: the original, or `width` wide (one of
  `Tore.Recipes.Pictures.widths/0`). Nil when the recipe has no picture.
  """
  @spec path(recipe(), pos_integer() | nil) :: String.t() | nil
  def path(recipe, width \\ nil)
  def path(%{image_path: nil}, _width), do: nil
  def path(%{id: id, image_path: key}, nil), do: ~p"/images/recipes/#{id}?#{[v: version(key)]}"

  def path(%{id: id, image_path: key}, width),
    do: ~p"/images/recipes/#{id}?#{[v: version(key), w: width]}"

  @doc "A `srcset` of the card and big widths, for a picture whose shown size varies with the screen."
  @spec srcset(recipe()) :: String.t() | nil
  def srcset(%{image_path: nil}), do: nil
  def srcset(recipe), do: Enum.map_join([720, 1440], ", ", &"#{__MODULE__.path(recipe, &1)} #{&1}w")

  @doc "A short, stable version for a stored key."
  @spec version(String.t()) :: String.t()
  def version(key) when is_binary(key) do
    :crypto.hash(:sha256, key) |> binary_part(0, 8) |> Base.url_encode64(padding: false)
  end
end
