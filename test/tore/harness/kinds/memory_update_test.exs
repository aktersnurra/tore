defmodule Tore.Harness.Kinds.MemoryUpdateTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.MemoryBatch
  alias Tore.Harness.Kinds.MemoryUpdate
  alias Tore.Household.Memory

  setup do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    %{ctx: capture_ctx(home_scope().household_id, user_fixture().id)}
  end

  defp notes, do: home_scope() |> Memory.list("notes") |> Enum.map(& &1.text)
  defp add(text), do: %{"action" => "add", "content" => text}

  defp runs do
    Repo.all(
      from(r in KitchenRun, where: r.kind == "memory_update_run"),
      Tore.Scope.repo_opts(home_scope())
    )
  end

  test "a patch says Updated and a remove says Forgot, and each undoes", %{ctx: ctx} do
    Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)

    patch =
      Dispatch.memory(
        "notes",
        [%{"action" => "patch", "old_text" => "fredagar", "content" => "lördagar"}],
        ctx
      )

    assert patch.text == "Uppdaterat: Pizza på lördagar."
    assert notes() == ["Pizza på lördagar."]

    forget = Dispatch.memory("notes", [%{"action" => "remove", "old_text" => "Pizza"}], ctx)
    assert forget.text == "Glömt: Pizza på lördagar."
    assert notes() == []

    {:ok, _} = Runs.revert(home_scope(), forget.run_stream_id)
    {:ok, _} = Runs.revert(home_scope(), patch.run_stream_id)
    assert notes() == ["Pizza på fredagar."]
  end

  test "a batch that doesn't fit opens no run and has no text, only the rejection", %{ctx: ctx} do
    bubble = Dispatch.memory("notes", [%{"action" => "remove", "old_text" => "Tacos"}], ctx)

    assert bubble.text == ""
    assert bubble.rejection["error"] =~ "no entry matches"
    assert runs() == []
  end

  test "a malformed call reaches the model as a rejection, and the person sees nothing", %{
    ctx: ctx
  } do
    usage = %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}
    call = %{id: "c1", name: "memory", args: %{"target" => "notes", "operations" => "add it"}}
    test_pid = self()

    Tore.MockLLM
    |> Mox.expect(:chat_with_tools, fn _, _, _, _ -> {:ok, {:tool_calls, [call]}, usage} end)
    |> Mox.expect(:chat_with_tools, fn _, msgs, _, _ ->
      send(test_pid, {:answer, Jason.decode!(List.last(msgs).content)})
      {:ok, {:message, "Okej."}, usage}
    end)

    {:ok, bubbles} = Tore.Capture.Router.route("kom ihåg det", [], ctx)

    assert_receive {:answer, %{"status" => "rejected", "rejection" => %{"error" => error}}}
    assert error =~ "operations"
    assert [%{text: ""}, %{text: "Okej."}] = Enum.map(bubbles, &Map.take(&1, [:text]))
    assert runs() == []
  end

  test "a saved note reaches the model with the memory as it now is", %{ctx: ctx} do
    bubble = Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)
    assert bubble.memory =~ "Pizza på fredagar."
  end

  test "saying something already noted changes nothing and offers no undo", %{ctx: ctx} do
    Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)
    again = Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)

    assert again.text == "Redan noterat."
    refute Map.has_key?(again, :run_stream_id)
    assert notes() == ["Pizza på fredagar."]
  end

  # One batch on the notes through a run, as an MCP or Capture write submits it.
  defp write(operations) do
    batch = %MemoryBatch{target: "notes", operations: operations}
    Runs.submit(home_scope(), MemoryUpdate, [batch], %{batch: batch})
  end

  defp texts, do: home_scope() |> Memory.list() |> Enum.map(& &1.text)

  defp seed(entries) do
    {:ok, %KitchenRun{status: :applied}} = write(Enum.map(entries, &add/1))
    {:ok, texts()}
  end

  test "undo restores memory after an add, a patch and a remove" do
    {:ok, seeded} = seed(["Friday pizza", "Skips dinner most Thursdays"])

    {:ok, run} =
      write([
        add("Taco Tuesdays"),
        %{"action" => "patch", "old_text" => "most Thursdays", "content" => "Thursdays in term"},
        %{"action" => "remove", "old_text" => "Friday pizza"}
      ])

    assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), run.id)
    assert texts() == seeded
  end

  test "undoing chained patches oldest first still ends where they started" do
    {:ok, seeded} = seed(["Skips dinner most Thursdays"])

    patch = fn old, new ->
      write([%{"action" => "patch", "old_text" => old, "content" => new}])
    end

    {:ok, %KitchenRun{status: :applied} = a} = patch.("most Thursdays", "Thursdays in term time")
    {:ok, %KitchenRun{status: :applied} = b} = patch.("in term time", "in spring term")

    assert {:ok, _} = Runs.revert(home_scope(), a.id)
    assert {:ok, _} = Runs.revert(home_scope(), b.id)
    assert texts() == seeded
  end

  test "a batch that no longer fits when applied fails as rejected and changes nothing" do
    {:ok, _} = seed(["Friday pizza"])
    [entry] = Memory.list(home_scope())

    batch = %MemoryBatch{
      target: "notes",
      operations: [%{"action" => "remove", "old_text" => "Friday pizza"}]
    }

    # Removed in Settings between verify and apply.
    :ok = Memory.forget(home_scope(), entry.id)

    assert {:fail, :memory_rejected, :reject} =
             MemoryUpdate.apply_proposal([batch], %{
               scope: home_scope(),
               run: %KitchenRun{id: "run-x"}
             })
  end

  test "undo restores memory across many generated batches" do
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

        outcome =
          case write(operations) do
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
end
