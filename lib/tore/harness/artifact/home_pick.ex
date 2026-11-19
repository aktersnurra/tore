defmodule Tore.Harness.Artifact.HomePick do
  @moduledoc """
  Where the app opens, which quick swaps sit above the chat box, and the one note Today may show
  (`Tore.Home`). Output of `:home_pick_run`. `source` is :model for a pick pi set; :rules is the
  fixed rule's, which is never stored now.
  """

  @behaviour Tore.Harness.Artifact

  @enforce_keys [:screen, :source, :swaps]
  defstruct [:screen, :source, :swaps, note: nil]

  @type t :: %__MODULE__{
          screen: Tore.Home.screen(),
          source: :model | :rules,
          swaps: [Tore.Home.swap_key()],
          note: Tore.Home.note_key() | nil
        }

  @impl true
  def kind, do: "HomePick"

  @impl true
  def to_json(%__MODULE__{} = pick) do
    %{
      "screen" => Atom.to_string(pick.screen),
      "source" => Atom.to_string(pick.source),
      "swaps" => Enum.map(pick.swaps, &Atom.to_string/1),
      "note" => pick.note && Atom.to_string(pick.note)
    }
  end

  # Only ever written from this struct's own atoms. A refused pick is stored on its failed run
  # too, so this doesn't check them against the lists: `verify` does.
  @impl true
  def from_json(%{"screen" => screen, "source" => source, "swaps" => swaps} = json) do
    %__MODULE__{
      screen: String.to_existing_atom(screen),
      source: String.to_existing_atom(source),
      swaps: Enum.map(swaps, &String.to_existing_atom/1),
      note: json["note"] && String.to_existing_atom(json["note"])
    }
  end
end
