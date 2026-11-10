defmodule Tore.Household.HouseholdInsight do
  use Ecto.Schema
  import Ecto.Changeset

  schema "household_insights" do
    field :household_id, :integer
    field :kind, :string
    field :body, :string
    field :confidence, :float, default: 0.5
    field :evidence, :string
    field :status, :string, default: "active"
    field :generated_at, :utc_datetime
    timestamps(updated_at: false)
  end

  @valid_statuses ~w[active superseded dismissed]
  @valid_kinds ~w[skip_pattern cascade_success time_preference cuisine_fatigue variety_win]

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [:kind, :body, :confidence, :evidence, :status, :generated_at])
    |> validate_required([:kind, :body, :confidence, :generated_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
