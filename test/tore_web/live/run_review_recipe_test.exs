defmodule ToreWeb.RunReviewRecipeTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    user = user_fixture(name: "Tester")

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})

    {:ok,
     conn: conn, user: user, household: household, plan_stream_id: "plan:" <> Ecto.UUID.generate()}
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
    p = proposal()

    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _c, plan -> {:proposal, p, %{}, plan} end
    }

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, %State.NeedsUser{} = state} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make it vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17],
        extra_tools: [proposal_tool]
      })

    state
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
    state = needs_user_run(ctx)

    {:ok, _view, html} = live(conn, ~p"/runs/#{state.stream_id}")

    assert html =~ "Vegetarian Miso Ramen"
    assert html =~ "firm tofu"
  end

  test "confirming saves the recipe", %{conn: conn} = ctx do
    state = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{state.stream_id}")

    view |> element("button[type=submit]") |> render_click()
    await_run_tasks()

    assert [%{title: "Vegetarian Miso Ramen"}] = Tore.Recipes.list(home_scope())
  end

  test "discarding saves nothing", %{conn: conn} = ctx do
    state = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{state.stream_id}")

    view |> element("button[phx-click=ask_discard]") |> render_click()
    view |> element("button[phx-click=confirm_discard]") |> render_click()
    await_run_tasks()

    assert Tore.Recipes.list(home_scope()) == []
    assert {:ok, %State.Discarded{}} = Tore.Harness.Run.load(home_scope(), state.stream_id)
  end
end
