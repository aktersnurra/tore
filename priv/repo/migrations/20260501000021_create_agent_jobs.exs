defmodule Tore.Repo.Migrations.CreateAgentJobs do
  use Ecto.Migration

  def change do
    create table(:agent_jobs) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :task, :string, null: false
      add :week, :date
      add :details, :text
      add :status, :string, null: false
      add :summary, :text
      add :cost_usd, :float, default: 0.0, null: false
      add :finished_at, :utc_datetime
      timestamps(updated_at: false)
    end

    create index(:agent_jobs, [:household_id, :task, :week])

    # A person's chats with pi; pi keeps what was said, this is each one's name.
    create table(:chats) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:chats, [:household_id, :user_id, :updated_at])
  end
end
