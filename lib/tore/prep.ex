defmodule Tore.Prep do
  @moduledoc """
  The week's prep guide. pi writes it as a background job (`start/2`,
  `harness/tasks/prep_guide.md`) and saves it with `save_prep_guide`; the Prep screen hears
  `{:prep_guide_saved, guide}` on `topic/1`.
  """

  import Ecto.Query

  alias Tore.{Repo, Prep.PrepGuide, Scope}

  @doc "Asks pi to write the guide for the week starting `week_start`, if AI is on."
  @spec start(Scope.t(), Date.t()) :: :ok | {:error, term()}
  def start(%Scope{} = scope, %Date{} = week_start) do
    with :ok <- Tore.Pi.check(scope),
         do: Tore.Agent.start(scope, "prep_guide", "Week starting #{week_start}.")
  end

  def topic(%Scope{household_id: id}), do: "prep:#{id}"

  def save_guide(%Scope{} = scope, attrs) do
    %PrepGuide{household_id: scope.household_id}
    |> PrepGuide.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:timeline, :cascade_map, :storage_notes, :daily_assembly, :prep_session, :instructions]},
      conflict_target: [:household_id, :week_start],
      returning: true
    )
    |> tap(fn
      {:ok, guide} ->
        Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), {:prep_guide_saved, guide})

      _ ->
        :ok
    end)
  end

  def get_guide_for_week(%Scope{} = scope, week_start) do
    Repo.one(from(g in PrepGuide, where: g.week_start == ^week_start), Scope.repo_opts(scope))
  end
end
