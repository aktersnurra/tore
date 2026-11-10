defmodule Tore.Harness.Kinds.MemoryUpdateTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Household.Memory

  setup do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    %{ctx: %{household_id: home_scope().household_id, user_id: user_fixture().id}}
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

  test "a batch that doesn't fit opens no run, and only the model hears why", %{ctx: ctx} do
    bubble = Dispatch.memory("notes", [%{"action" => "remove", "old_text" => "Tacos"}], ctx)

    assert bubble.text == ""
    assert bubble.rejection["error"] =~ "no entry matches"
    assert runs() == []
  end

  test "saying something already noted changes nothing and offers no undo", %{ctx: ctx} do
    Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)
    again = Dispatch.memory("notes", [add("Pizza på fredagar.")], ctx)

    assert again.text == "Redan noterat."
    refute Map.has_key?(again, :run_stream_id)
    assert notes() == ["Pizza på fredagar."]
  end
end
