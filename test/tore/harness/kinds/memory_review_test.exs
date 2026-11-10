defmodule Tore.Harness.Kinds.MemoryReviewTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds.MemoryReview
  alias Tore.Household.Memory

  setup :verify_on_exit!

  @usage %{prompt_tokens: 3, completion_tokens: 2, cost_usd: 0.25}

  defp planned_week do
    recipe =
      Repo.insert!(%Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Ärtsoppa",
        recipe_type: :meal
      })

    plan = Tore.Streams.plan(home_scope(), Date.utc_today())
    {:ok, _} = Tore.Planning.assign_recipe(home_scope(), plan, "thu_dinner", recipe.id, 4)
    :ok
  end

  defp reply(batches), do: fn _system, _user, _opts -> {:ok, %{"batches" => batches}, @usage} end
  defp add(text), do: %{"action" => "add", "content" => text}
  defp review, do: Runs.start(home_scope(), MemoryReview, %{})
  defp texts, do: home_scope() |> Memory.list() |> Enum.map(& &1.text)

  test "applies the review's batches, and the run says what changed" do
    planned_week()

    expect(
      Tore.MockLLM,
      :text,
      reply([%{"target" => "notes", "operations" => [add("Ärtsoppa on Thursdays")]}])
    )

    assert {:ok, %KitchenRun{status: :applied, actor: :system} = run} = review()
    assert texts() == ["Ärtsoppa on Thursdays"]
    assert [%{changes: [%{"kind" => "noted", "text" => "Ärtsoppa on Thursdays"}]}] = run.artifacts
    assert run == Runs.get(home_scope(), run.id)
  end

  test "a week with nothing to change applies nothing" do
    planned_week()
    expect(Tore.MockLLM, :text, reply([]))

    assert {:ok, %KitchenRun{status: :applied, undo: {:steps, []}}} = review()
    assert texts() == []
  end

  test "with no planning to read, it makes no call" do
    expect(Tore.MockLLM, :text, 0, reply([]))
    assert {:ok, %KitchenRun{status: :applied, prompt_tokens: 0}} = review()
  end

  test "a rejected answer is retried once, with the rejection" do
    planned_week()

    Tore.MockLLM
    |> expect(
      :text,
      reply([
        %{"target" => "notes", "operations" => [%{"action" => "remove", "old_text" => "nothing"}]}
      ])
    )
    |> expect(:text, fn _system, user, _opts ->
      assert user =~ "no entry matches"

      {:ok,
       %{"batches" => [%{"target" => "notes", "operations" => [add("Ärtsoppa on Thursdays")]}]},
       @usage}
    end)

    assert {:ok, %KitchenRun{status: :applied, prompt_tokens: 6}} = review()
    assert texts() == ["Ärtsoppa on Thursdays"]
  end

  test "rejected twice, the run fails and memory is unchanged" do
    planned_week()

    stub(
      Tore.MockLLM,
      :text,
      reply([%{"target" => "profile", "operations" => [add("Anna is allergic to nuts")]}])
    )

    assert {:ok, %KitchenRun{status: :failed, failure_code: :memory_rejected}} = review()
    assert texts() == []
  end

  test "a reply in the wrong shape fails the run" do
    planned_week()
    expect(Tore.MockLLM, :text, fn _, _, _ -> {:ok, %{"insights" => []}, @usage} end)

    assert {:error, {:step_failed, :invalid_response}} = review()
  end

  test "undo restores memory after an add, a patch and a remove" do
    planned_week()
    {:ok, seeded} = seed(["Friday pizza", "Skips dinner most Thursdays"])

    expect(
      Tore.MockLLM,
      :text,
      reply([
        %{
          "target" => "notes",
          "operations" => [
            add("Taco Tuesdays"),
            %{
              "action" => "patch",
              "old_text" => "most Thursdays",
              "content" => "Thursdays in term time"
            },
            %{"action" => "remove", "old_text" => "Friday pizza"}
          ]
        }
      ])
    )

    {:ok, run} = review()
    assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), run.id)
    assert texts() == seeded
  end

  test "undoing chained patches oldest first still ends where they started" do
    planned_week()
    {:ok, seeded} = seed(["Skips dinner most Thursdays"])

    patch = fn old, new ->
      expect(
        Tore.MockLLM,
        :text,
        reply([
          %{
            "target" => "notes",
            "operations" => [%{"action" => "patch", "old_text" => old, "content" => new}]
          }
        ])
      )

      {:ok, %KitchenRun{status: :applied} = run} = review()
      run
    end

    a = patch.("most Thursdays", "Thursdays in term time")
    b = patch.("in term time", "in spring term")

    assert {:ok, _} = Runs.revert(home_scope(), a.id)
    assert {:ok, _} = Runs.revert(home_scope(), b.id)
    assert texts() == seeded
  end

  test "a batch that no longer fits when applied fails as rejected and changes nothing" do
    planned_week()
    {:ok, _} = seed(["Friday pizza"])
    [entry] = Memory.list(home_scope())

    batches = [
      %Tore.Harness.Artifact.MemoryBatch{
        target: "notes",
        operations: [%{"action" => "remove", "old_text" => "Friday pizza"}]
      }
    ]

    run = %KitchenRun{id: "run-x"}

    # Removed in Settings between verify and apply.
    :ok = Memory.forget(home_scope(), entry.id)

    assert {:fail, :memory_rejected, :reject} =
             MemoryReview.apply_proposal(batches, %{scope: home_scope(), run: run})
  end

  test "a crash in the LLM call fails the run" do
    planned_week()
    stub(Tore.MockLLM, :text, fn _, _, _ -> raise "connection reset" end)

    assert {:error, {:run_crashed, %RuntimeError{}}} = review()
    assert texts() == []
  end

  test "undo restores memory across many generated batches" do
    planned_week()
    :rand.seed(:exsss, {4, 5, 6})
    {:ok, before} = seed(["Friday pizza", "Taco Tuesdays", "Shops on Saturdays"])

    outcomes =
      for _ <- 1..25 do
        operations =
          for _ <- 1..Enum.random(1..4) do
            case Enum.random([:add, :remove, :patch]) do
              :add ->
                add("Note #{System.unique_integer([:positive])}")

              :remove ->
                %{"action" => "remove", "old_text" => Enum.random(texts())}

              :patch ->
                %{
                  "action" => "patch",
                  "old_text" => Enum.random(texts()),
                  "content" => "Changed #{System.unique_integer([:positive])}"
                }
            end
          end

        # A rejected batch is retried with the same answer, so the run fails.
        stub(Tore.MockLLM, :text, reply([%{"target" => "notes", "operations" => operations}]))

        outcome =
          case review() do
            {:ok, %KitchenRun{status: :applied} = run} ->
              assert {:ok, _} = Runs.revert(home_scope(), run.id)
              :applied

            {:ok, %KitchenRun{status: :failed}} ->
              :failed
          end

        assert Enum.sort(texts()) == Enum.sort(before)
        outcome
      end

    # Both paths ran, so the loop proved something about applied runs.
    assert :applied in outcomes and :failed in outcomes
  end

  # Memory written by a run that applied straight away, as a seed.
  defp seed(entries) do
    Tore.MockLLM
    |> expect(:text, reply([%{"target" => "notes", "operations" => Enum.map(entries, &add/1)}]))

    {:ok, %KitchenRun{status: :applied}} = review()
    {:ok, texts()}
  end
end
