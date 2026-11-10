defmodule ToreWeb.RunReviewRecipeTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds.PlannerCommand

  setup do
    household = home_household()
    user = user_fixture(name: "Tester")

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    # A confirmed recipe's picture is made after commit; these tests don't look at it.
    stub(Tore.MockLLM, :text, fn _, _, _ -> {:error, :ai_unavailable} end)

    {:ok, conn: conn, user: user, household: household}
  end

  defp proposal do
    %RecipeProposal{
      title: "Vegetarian Miso Ramen",
      instructions: "Simmer the broth.",
      base_servings: 4,
      ingredients: [%{name: "firm tofu", quantity: "300", unit: "g"}],
      tags: ["vegetarian"],
      source: :generation,
      instruction: "make it vegetarian",
      pending_assignment: nil
    }
  end

  defp needs_user_run(ctx) do
    week = ~D[2026-08-17]

    {:ok, %KitchenRun{status: :needs_user} = run} =
      Runs.submit(scope_fixture(ctx.user), PlannerCommand, proposal(), %{
        command: "make it vegetarian",
        plan_stream_id: Tore.Streams.plan(home_scope(), week),
        week_start: week
      })

    run
  end

  # The commit is fire-and-forget through Tore.TaskSupervisor (same as the
  # receipt card), so the assertion has to wait for the child to finish rather
  # than read the catalog straight after the click.
  defp await_run_tasks do
    Tore.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :timeout
      end
    end)
  end

  test "the review page shows the proposed recipe", %{conn: conn} = ctx do
    run = needs_user_run(ctx)

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "Vegetarian Miso Ramen"
    assert html =~ "firm tofu"
  end

  test "confirming saves the recipe", %{conn: conn} = ctx do
    run = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view |> element(~s(button[phx-click="save_recipe"])) |> render_click()
    await_run_tasks()

    assert [%{title: "Vegetarian Miso Ramen"}] = Tore.Recipes.list(home_scope())
  end

  test "discarding saves nothing", %{conn: conn} = ctx do
    run = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    view |> element("button[phx-click=ask_discard]") |> render_click()
    view |> element("button[phx-click=confirm_discard]") |> render_click()
    await_run_tasks()

    assert Tore.Recipes.list(home_scope()) == []
    assert %KitchenRun{status: :discarded} = Runs.get(home_scope(), run.id)
  end
end
