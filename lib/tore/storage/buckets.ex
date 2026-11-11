defmodule Tore.Storage.Buckets do
  @moduledoc """
  Centralised S3 bucket names.

  * `recipes/` — long-lived recipe imagery (lives as long as the recipe).
  """

  @recipes "tore-recipes"

  def recipes, do: @recipes

  def all, do: [@recipes]
end
