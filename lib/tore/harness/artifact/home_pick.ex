defmodule Tore.Harness.Artifact.HomePick do
  @moduledoc """
  Where the app opens and which quick swaps sit above the chat box (`Tore.Home`). Output of
  `:home_pick_run`. `source` says whether the decision model picked them or the fixed rule did.
  """

  @behaviour Tore.Harness.Artifact

  @enforce_keys [:screen, :source, :swaps]
  defstruct [:screen, :source, :swaps]

  @type t :: %__MODULE__{
          screen: Tore.Home.screen(),
          source: :model | :rules,
          swaps: [Tore.Home.swap_key()]
        }

  @impl true
  def kind, do: "HomePick"

  @impl true
  def summary(%__MODULE__{screen: screen, swaps: swaps}),
    do: %{counts: %{swaps: length(swaps)}, text_fallback: "Opens #{screen}"}

  @impl true
  def is_rationale_complete(%__MODULE__{}), do: true

  @impl true
  def to_json(%__MODULE__{} = pick) do
    %{
      "screen" => Atom.to_string(pick.screen),
      "source" => Atom.to_string(pick.source),
      "swaps" => Enum.map(pick.swaps, &Atom.to_string/1)
    }
  end

  # Only ever written from this struct's own atoms. A refused pick is stored on its failed run
  # too, so this doesn't check them against the lists: `verify` does.
  @impl true
  def from_json(%{"screen" => screen, "source" => source, "swaps" => swaps}) do
    %__MODULE__{
      screen: String.to_existing_atom(screen),
      source: String.to_existing_atom(source),
      swaps: Enum.map(swaps, &String.to_existing_atom/1)
    }
  end
end
