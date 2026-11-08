defmodule Tore.Repo.Migrations.CreateHouseholdInsights do
  use Ecto.Migration

  def change do
    create table(:household_insights) do
      add :kind, :string, null: false
      add :body, :text, null: false
      add :confidence, :float, null: false, default: 0.5
      add :evidence, :text
      add :status, :string, null: false, default: "active"
      add :generated_at, :utc_datetime, null: false
      timestamps(updated_at: false)
    end

    create index(:household_insights, [:status])
  end
end
