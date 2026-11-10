defmodule Tore.Repo.Migrations.CreateAiOperations do
  use Ecto.Migration

  def change do
    create table(:ai_operations) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :run_stream_id, :string, null: false
      add :step_index, :integer, null: false, default: 0
      add :kind, :string, null: false
      add :payload, :text
      add :result, :text
      add :undo_op_id, :integer
      add :inserted_at, :utc_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create unique_index(:ai_operations, [:run_stream_id, :step_index])
  end
end
