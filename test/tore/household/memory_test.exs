defmodule Tore.Household.MemoryTest do
  use Tore.DataCase, async: true

  alias Tore.Harness.Capsules.MemoryCapsule
  alias Tore.Household.Memory
  alias Tore.Household.Memory.Ops

  @run_id "run-test"

  defp write(scope, store, operations) do
    {:ok, plan} =
      Ops.plan(
        store,
        Enum.map(Memory.list(scope, store), &Map.take(&1, [:id, :text])),
        operations
      )

    Memory.write(scope, store, plan, @run_id)
  end

  defp add(text), do: %{"action" => "add", "content" => text}

  setup do
    # Entries name the run that wrote them, so the run row must exist.
    home_scope()
    |> Tore.Harness.KitchenRun.open(
      %{id: @run_id, kind: "memory_review_run", actor: :system, input: %{}},
      DateTime.utc_now()
    )
    |> Repo.insert!()

    :ok
  end

  test "a write names its run, and a patch points at the entry it replaced" do
    %{added: [first]} = write(home_scope(), "notes", [add("Skips dinner most Thursdays")])

    %{added: [second], forgotten: [^first], changes: [%{"kind" => "updated"}]} =
      write(home_scope(), "notes", [
        %{
          "action" => "patch",
          "old_text" => "most Thursdays",
          "content" => "Thursdays in term time"
        }
      ])

    assert [%{id: ^second, supersedes_id: ^first, run_id: @run_id}] = Memory.list(home_scope())
  end

  test "another household sees none of it" do
    write(home_scope(), "profile", [add("Cooks for four")])
    other = scope_fixture(household_fixture())

    assert Memory.list(other) == []
    assert Memory.snapshot(other) == nil
    assert {:error, :not_found} = Memory.forget(other, hd(Memory.list(home_scope())).id)
  end

  test "a forgotten entry stays stored but leaves the snapshot" do
    %{added: [id]} = write(home_scope(), "notes", [add("Friday pizza")])
    assert :ok = Memory.forget(home_scope(), id)

    assert Memory.list(home_scope()) == []

    assert %Memory{forgotten_at: %DateTime{}} =
             Repo.get!(Memory, id, household_id: home_scope().household_id)
  end

  test "restore takes back a write: what was added goes, what was forgotten returns" do
    %{added: [kept]} = write(home_scope(), "notes", [add("Friday pizza")])

    %{added: added, forgotten: forgotten} =
      write(home_scope(), "notes", [
        %{"action" => "remove", "old_text" => "Friday pizza"},
        add("Taco Tuesdays")
      ])

    assert :ok = Memory.restore(home_scope(), added, forgotten)
    assert [%{id: ^kept}] = Memory.list(home_scope())
  end

  test "restore refuses another household's entries" do
    %{added: [id]} = write(home_scope(), "notes", [add("Friday pizza")])
    other = scope_fixture(household_fixture())
    assert_raise MatchError, fn -> Memory.restore(other, [id], []) end
  end

  test "the capsule shows both parts with usage, nothing cut at the limit, and nothing when empty" do
    ctx = %{household_id: home_scope().household_id}
    assert MemoryCapsule.to_prompt(MemoryCapsule.build(ctx)) == nil

    long = String.duplicate("a", 1_300)
    write(home_scope(), "profile", [add(long)])

    prompt = MemoryCapsule.to_prompt(MemoryCapsule.build(ctx))
    assert prompt =~ "HOUSEHOLD PROFILE"
    assert prompt =~ "[95% — 1,300/1,375 chars]"
    assert prompt =~ long
    assert prompt =~ "NOTES"
    assert prompt =~ "(empty)"
  end
end
