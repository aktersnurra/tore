defmodule Tore.AiOperations.AiOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_operations" do
    field :household_id, :integer
    field :run_stream_id, :string
    field :kind, :string
    field :payload, :string
    field :result, :string
    field :step_index, :integer, default: 0
    field :undo_op_id, :integer
    field :inserted_at, :utc_datetime, autogenerate: false
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:run_stream_id, :kind, :payload, :result, :step_index, :undo_op_id])
    |> validate_required([:run_stream_id, :kind])
    |> unique_constraint([:run_stream_id, :step_index],
      name: :ai_operations_run_stream_id_step_index_index
    )
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
