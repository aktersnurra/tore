defmodule Tore.Harness.KitchenRun do
  @moduledoc """
  One run as one row. A run returned to a caller equals the same run read back: every column
  type casts by encoding and decoding, so there is no in-memory shape the database can't hold.

  Status changes go through `KitchenRun.Transition`, and the CHECK constraints on `runs` hold
  the same rules in the database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tore.Harness.KitchenRun.Types

  @failure_codes ~w(
    internal_error interrupted ai_unavailable budget_exceeded
    slot_pinned slot_eating_out servings_missing skip_not_explicit leftover_no_source dietary_violation
    invalid_servings missing_store missing_date missing_total date_in_future sum_mismatch
    missing_provenance negative_quantity last_seen_regressed
    missing_title missing_instructions no_ingredients empty_ingredient_name near_duplicate
    memory_rejected unknown_ingredient
  )a

  @type status :: :running | :needs_user | :applied | :failed | :reverted | :discarded
  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "runs" do
    field :household_id, :integer
    field :user_id, :integer
    field :kind, :string
    field :actor, Ecto.Enum, values: [:user, :system, :mcp]
    field :surface, Ecto.Enum, values: [:today, :plan, :shop]

    field :status, Ecto.Enum,
      values: [:running, :needs_user, :applied, :failed, :reverted, :discarded]

    field :phase, Ecto.Enum, values: [:gathering_context, :proposing, :verifying]
    field :input, Types.JsonMap
    field :artifacts, Types.Artifacts, default: []
    field :question, :string
    field :failure_code, Ecto.Enum, values: @failure_codes
    field :failure_message, :string
    field :repair_action, Types.RepairAction
    field :discard_reason, Ecto.Enum, values: [:user_discarded, :ttl_expired]
    field :undo, Types.Undo
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cost_usd, Types.Usd, default: Decimal.new(0)
    field :opened_at, :utc_datetime_usec
    field :applied_at, :utc_datetime_usec
    field :reverted_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
  end

  @spec failure_codes() :: [atom()]
  def failure_codes, do: @failure_codes

  @spec new_id() :: String.t()
  def new_id, do: "run-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  @doc "A new `running` row. The household and user come from the caller's scope."
  @spec open(Tore.Scope.t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def open(%Tore.Scope{} = scope, attrs, %DateTime{} = now) do
    %__MODULE__{
      id: Map.get(attrs, :id) || new_id(),
      household_id: scope.household_id,
      user_id: scope.user_id,
      status: :running
    }
    |> cast(Map.put(attrs, :opened_at, now), [
      :kind,
      :actor,
      :surface,
      :phase,
      :input,
      :opened_at
    ])
    |> validate_required([:kind, :actor, :input, :opened_at])
  end

  @doc "Column changes a transition or the flow produced: never the identity columns."
  @spec change(t(), map()) :: Ecto.Changeset.t()
  def change(%__MODULE__{} = run, changes) do
    cast(run, changes, [
      :status,
      :phase,
      :artifacts,
      :question,
      :failure_code,
      :failure_message,
      :repair_action,
      :discard_reason,
      :undo,
      :prompt_tokens,
      :completion_tokens,
      :cost_usd,
      :applied_at,
      :reverted_at,
      :closed_at
    ])
  end
end
