defmodule Tore.Harness.Kinds.HomePick do
  @moduledoc """
  The screen the app opens on, the quick swaps above the chat box and Today's note
  (`Tore.Home`), as pi set them with `set_home_pick` in a `home_pick` job. It changes nothing
  else, so its undo is empty.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Home
  alias Tore.Harness.Artifact.HomePick

  @impl true
  def kind, do: "home_pick_run"

  @impl true
  def surface, do: nil

  @impl true
  def open(_ctx), do: %{input: %{}, actor: :system}

  @impl true
  def verify(%HomePick{screen: screen, swaps: swaps, note: note}, _ctx) do
    if screen in Home.screens() and length(swaps) <= Home.max_swaps() and
         swaps == Enum.uniq(swaps) and Enum.all?(swaps, &(&1 in Home.swap_keys())) and
         :"open_#{screen}" not in swaps and (note == nil or note in Home.note_keys()),
       do: :ok,
       else: {:fail, :invalid_home_pick, :reject}
  end

  @impl true
  def review_question(_pick), do: nil

  @impl true
  def apply_proposal(%HomePick{} = pick, _ctx), do: {:ok, {:steps, []}, [pick]}
end
