defmodule Tore.Repo.Migrations.CreateLlmUsage do
  use Ecto.Migration

  def change do
    create table(:llm_usage) do
      add :feature, :string, null: false
      add :prompt_tokens, :integer, default: 0
      add :completion_tokens, :integer, default: 0
      add :cost_usd, :float, default: 0.0
      timestamps(updated_at: false)
    end
  end
end
