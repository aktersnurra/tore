defmodule Tore.RunFixtures do
  @moduledoc "Runs in a given status, for tests of what reads them."

  alias Tore.Harness.Artifact.CostEntry
  alias Tore.Harness.KitchenRun
  alias Tore.Harness.KitchenRun.Transition
  alias Tore.Repo
  alias Tore.Storage.RunPhotos

  @doc "A running run in the scope's household whose input holds a stored photo. Returns `{id, key}`."
  def run_with_photo_fixture(scope, bytes \\ "photo bytes") do
    id = KitchenRun.new_id()
    {:ok, key} = RunPhotos.store(scope, id, bytes)

    open(scope, %{
      id: id,
      kind: "receipt_ingestion_run",
      surface: :shop,
      input: %{"image_path" => key}
    })

    {id, key}
  end

  @doc "Fails the run, which finishes it."
  def fail_run(scope, id) do
    run = Repo.get!(KitchenRun, id, Tore.Scope.repo_opts(scope))
    move(run, {:fail, :internal_error, nil, nil})
  end

  @doc "A receipt waiting for review, opened at `opened_at`."
  def pending_review_fixture(scope, opened_at \\ DateTime.utc_now()) do
    cost = %CostEntry{
      store_name: "ICA",
      date: ~D[2026-11-04],
      total: Decimal.new("100"),
      line_items: [
        %{
          name: "MJÖLK",
          quantity: nil,
          unit: nil,
          total_price: Decimal.new("20"),
          category: "dairy"
        }
      ]
    }

    scope
    |> open(
      %{kind: "receipt_ingestion_run", surface: :shop, input: %{"image_path" => nil}},
      opened_at
    )
    |> move({:review, "The lines don't add up."}, %{artifacts: [cost]})
  end

  @doc "A planner run waiting on a question, which has nothing to review."
  def pending_question_fixture(scope) do
    scope
    |> open(%{kind: "planner_command_run", surface: :plan, input: %{}})
    |> move({:ask, "Which Monday?"})
  end

  defp open(scope, attrs, at \\ DateTime.utc_now()) do
    scope
    |> KitchenRun.open(Map.put(attrs, :actor, :user), at)
    |> Repo.insert!()
  end

  defp move(run, action, extra \\ %{}) do
    {:ok, changes} = Transition.next(run, action, DateTime.utc_now())
    run |> KitchenRun.change(Map.merge(changes, extra)) |> Repo.update!()
  end
end
