defmodule Tore.ImageGen do
  @moduledoc """
  Transport behaviour for image generation. Takes a finished prompt and returns the image's bytes
  and what drawing it cost. pi describes the dish and `Tore.Recipes.draw_picture/3` adds the house
  style.
  """

  @type drawn :: %{image: binary(), cost_usd: float()}

  @callback generate_food_image(prompt :: String.t()) :: {:ok, drawn()} | {:error, term()}
end
