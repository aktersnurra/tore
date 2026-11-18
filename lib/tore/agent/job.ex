defmodule Tore.Agent.Job do
  @moduledoc """
  One harness job for a household: the task it ran, the week it was for when it has one, and
  what came back. The job's writes are runs of their own; this row is the job's summary and cost.
  """
  use Ecto.Schema

  schema "agent_jobs" do
    field :household_id, :integer
    field :task, :string
    field :week, :date
    field :status, Ecto.Enum, values: [:running, :succeeded, :failed, :timed_out]
    field :summary, :string
    field :cost_usd, :float, default: 0.0
    field :finished_at, :utc_datetime
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}
end
