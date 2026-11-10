defmodule Tore.Harness.TestKind do
  @moduledoc """
  A kind for testing `Tore.Harness.Runs` alone. It logs a receipt, and the run's `"mode"` input
  picks the path (see each clause), or anything else proposes the receipt in `ctx.entry`. A receipt from the store "Granska" waits for review.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Artifact.CostEntry
  alias Tore.Harness.Verifier.CostEntryVerifier

  @impl true
  def kind, do: "test_run"

  @impl true
  def surface, do: :shop

  @impl true
  def open(ctx), do: %{input: %{"mode" => Map.get(ctx, :mode, "apply")}, actor: :user}

  @impl true
  def propose(%{input: %{"mode" => "ask"}}, _ctx), do: {:ask, "Which store?"}
  def propose(%{input: %{"mode" => "refuse"}}, _ctx), do: {:error, :ai_unavailable}
  def propose(%{input: %{"mode" => "crash"}}, _ctx), do: raise("model went away")
  def propose(%{input: %{"mode" => "exit"}}, _ctx), do: exit(:timeout)
  def propose(%{input: %{"mode" => "blank_question"}}, _ctx), do: {:ask, "  "}

  def propose(_run, ctx),
    do: {:ok, ctx.entry, %{prompt_tokens: 3, completion_tokens: 2, cost_usd: 0.25}}

  # "race_discard": the run is discarded while a confirm resolves, as the TTL sweep might.
  @impl true
  def resolve(entry, %{
        scope: scope,
        run: %{status: :needs_user, input: %{"mode" => "race_discard"}} = run
      }) do
    {:ok, _} = Tore.Harness.Runs.discard(scope, run.id, :ttl_expired)
    {:ok, entry}
  end

  def resolve(entry, _ctx), do: {:ok, entry}

  @impl true
  def after_commit(%{status: :applied, input: %{"mode" => "after_commit_raises"}}),
    do: raise("photo store is down")

  def after_commit(_run), do: :ok

  @impl true
  def verify(%CostEntry{} = entry, _ctx), do: CostEntryVerifier.verify(entry, %{})

  @impl true
  def review_question(%CostEntry{store_name: "Granska"}), do: "Check the receipt."
  def review_question(_entry), do: nil

  @impl true
  def apply_proposal(%CostEntry{} = entry, %{scope: scope, run: run}) do
    {:ok, receipt} =
      Tore.Costs.log_receipt(scope, %{
        date: entry.date,
        store_name: entry.store_name,
        user_id: run.user_id,
        total_amount: entry.total
      })

    case run.input["mode"] do
      "write_then_error" -> {:error, :later_step_failed}
      "write_then_fail" -> {:fail, :sum_mismatch, :reject}
      _ -> {:ok, {:steps, [{:delete_receipt, receipt.id}]}, [entry]}
    end
  end
end
