defmodule ToreWeb.RecipeImage do
  @moduledoc """
  Where a recipe's picture is served, and the version that makes it cacheable.

  Each picture is stored under its own key (a new UUID every time one is drawn or fetched), so a
  hash of the key names that exact picture: it goes in the URL as `?v=` and is the response's
  ETag. A URL with the current version never changes, so the browser keeps it for a year without
  asking again; a new picture is a new URL.
  """

  use ToreWeb, :verified_routes

  @doc "The picture's URL, versioned by its key. Nil when the recipe has no picture."
  @spec path(%{id: integer(), image_path: String.t() | nil}) :: String.t() | nil
  def path(%{image_path: nil}), do: nil
  def path(%{id: id, image_path: key}), do: ~p"/images/recipes/#{id}?#{[v: version(key)]}"

  @doc "A short, stable version for a stored key."
  @spec version(String.t()) :: String.t()
  def version(key) when is_binary(key) do
    :crypto.hash(:sha256, key) |> binary_part(0, 8) |> Base.url_encode64(padding: false)
  end
end
