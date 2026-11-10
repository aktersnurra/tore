defmodule Tore.Costs.LLMUsage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "llm_usage" do
    field :household_id, :integer
    field :feature, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :float
    timestamps(updated_at: false)
  end

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [:feature, :prompt_tokens, :completion_tokens, :cost_usd])
    |> validate_required([:feature])
  end
end
