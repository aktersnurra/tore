defmodule Tore.Adapters.StubImageGen do
  @behaviour Tore.ImageGen

  # Minimal valid 1×1 transparent PNG
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 98, 0, 0, 0, 2, 0,
         1, 227, 81, 25, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  # The prompt goes to the process that asked, so a test can read it.
  @impl true
  def generate_food_image(prompt) do
    send(self(), {:image_prompt, prompt})
    {:ok, %{image: @png, cost_usd: 0.03}}
  end
end
