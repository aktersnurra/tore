defmodule Tore.WeekMode do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Tore.{Repo, Scope}

  @valid_modes ~w(normal low_effort budget_week use_pantry more_leftovers
                  high_protein freezer_week guest_week)

  schema "week_modes" do
    field :household_id, :integer
    field :mode, :string, default: "normal"
    field :week_start, :date
    timestamps(updated_at: false)
  end

  def changeset(wm, attrs) do
    wm
    |> cast(attrs, [:mode, :week_start])
    |> validate_required([:mode, :week_start])
    |> validate_inclusion(:mode, @valid_modes)
    |> unique_constraint([:household_id, :week_start])
  end

  def get_current_mode(%Scope{} = scope) do
    week_start = current_week_start()

    case Repo.one(
           from(wm in __MODULE__, where: wm.week_start == ^week_start),
           Scope.repo_opts(scope)
         ) do
      nil -> "normal"
      wm -> wm.mode
    end
  end

  def set_mode(%Scope{} = scope, mode) do
    week_start = current_week_start()
    attrs = %{mode: mode, week_start: week_start}

    existing =
      Repo.one(
        from(wm in __MODULE__, where: wm.week_start == ^week_start),
        Scope.repo_opts(scope)
      )

    (existing || %__MODULE__{household_id: scope.household_id})
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  def mode_prompt_fragment("normal"), do: nil

  def mode_prompt_fragment("low_effort") do
    "Current week mode: Low effort. Prefer meals with total time ≤30 minutes. " <>
      "Fewer unique cooking sessions. More leftovers where possible. Do not change pinned slots."
  end

  def mode_prompt_fragment("budget_week") do
    "Current week mode: Budget week. Prioritise meals using on-sale ingredients and pantry staples. " <>
      "Minimise unique grocery items."
  end

  def mode_prompt_fragment("use_pantry") do
    "Current week mode: Use pantry. Prioritise meals that use existing pantry inventory. " <>
      "Avoid requiring new ingredients where possible."
  end

  def mode_prompt_fragment("more_leftovers") do
    "Current week mode: More leftovers. Prefer recipes that produce extra servings. " <>
      "Plan for intentional leftover meals later in the week."
  end

  def mode_prompt_fragment("high_protein") do
    "Current week mode: High protein. Prefer meals high in protein. " <>
      "Increase meat, fish, and legume proportion."
  end

  def mode_prompt_fragment("freezer_week") do
    "Current week mode: Freezer week. Prioritise using frozen ingredients. " <>
      "Suggest meals compatible with freezer staples."
  end

  def mode_prompt_fragment("guest_week") do
    "Current week mode: Guest week. Plan for larger portions and more impressive recipes suitable for guests."
  end

  def mode_prompt_fragment(_), do: nil

  defp current_week_start do
    today = Date.utc_today()
    Date.add(today, -(Date.day_of_week(today) - 1))
  end
end
