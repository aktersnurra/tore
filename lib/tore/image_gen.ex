defmodule Tore.ImageGen do
  @moduledoc """
  Transport behaviour for image generation. Takes a finished prompt and returns image bytes. pi
  describes the dish and `Tore.Recipes.draw_picture/3` adds the house style.
  """

  @callback generate_food_image(prompt :: String.t()) ::
              {:ok, binary()} | {:error, term()}
end
