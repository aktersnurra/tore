defmodule Tore.Repo.Migrations.CreateAgentJobs do
  use Ecto.Migration

  def change do
    create table(:agent_jobs) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :task, :string, null: false
      add :week, :date
      add :status, :string, null: false
      add :summary, :text
      add :cost_usd, :float, default: 0.0, null: false
      add :finished_at, :utc_datetime
      timestamps(updated_at: false)
    end

    create index(:agent_jobs, [:household_id, :task, :week])
  end
end
