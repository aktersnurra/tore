defmodule Tore.Repo.Migrations.CreateLlmUsage do
  use Ecto.Migration

  def change do
    create table(:llm_usage) do
      add :household_id, references(:households, on_delete: :delete_all), null: false
      add :feature, :string, null: false
      add :prompt_tokens, :integer, default: 0
      add :completion_tokens, :integer, default: 0
      add :cost_usd, :float, default: 0.0
      timestamps(updated_at: false)
    end

    create index(:llm_usage, [:household_id, :inserted_at])
  end
end
