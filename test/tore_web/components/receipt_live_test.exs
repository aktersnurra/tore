defmodule ToreWeb.Components.ReceiptLiveTest do
  use ToreWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias ToreWeb.Components.ReceiptLive
  alias Tore.Harness.KitchenRun
  alias Tore.Harness.Artifact.PlanDiff

  # render_component/2 bypasses the LiveView mount (and ToreWeb.Live.Auth's
  # Gettext.put_locale), so without this it renders in the gettext default
  # locale instead of the "sv" that real users see. Pin "sv" so these tests
  # assert the actual rendered Swedish.
  setup do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    :ok
  end

  defp base_running do
    %KitchenRun{
      status: :running,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{command: "x"},
      opened_at: ~U[2026-06-02 12:00:00Z],
      phase: :proposing,
      artifacts: []
    }
  end

  test "renders phase label for Running" do
    html = render_component(ReceiptLive, id: "r", run: base_running())
    assert html =~ "Föreslår"
  end

  test "renders question for NeedsUser" do
    needs = %KitchenRun{
      status: :needs_user,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      question: "Which Monday?",
      artifacts: []
    }

    html = render_component(ReceiptLive, id: "r", run: needs)
    assert html =~ "Which Monday?"
  end

  test "renders summary for Applied with header text" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [%{slot_key: "mon", event_type: "MealSkipped", payload: %{}, rationale: ["x"]}]
    }

    applied = %KitchenRun{
      status: :applied,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      artifacts: [diff]
    }

    html = render_component(ReceiptLive, id: "r", run: applied)
    assert html =~ "Tore justerade planen"
    assert html =~ "Hoppade över"
    assert html =~ "Måndag"
  end

  test "renders failure for Failed with header text and user message" do
    failed = %KitchenRun{
      status: :failed,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      failure_code: :slot_locked,
      repair_action: nil,
      artifacts: []
    }

    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "kunde inte"
    refute html =~ "That slot is pinned."
  end

  test "Failed renders the message for :internal_error from failure_code" do
    failed = %KitchenRun{
      status: :failed,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      failure_code: :internal_error,
      repair_action: nil,
      artifacts: []
    }

    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "Tore kunde inte slutföra det — inget ändrades"
  end

  test "Failed renders a fallback message for an unknown failure_code" do
    failed = %KitchenRun{
      status: :failed,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      failure_code: :some_unknown,
      repair_action: nil,
      artifacts: []
    }

    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "Tore kunde inte slutföra det."
    refute html =~ "inget ändrades"
  end

  defp base_failed(code, repair \\ nil) do
    %KitchenRun{
      status: :failed,
      id: "run-f",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{command: "x"},
      opened_at: ~U[2026-06-08 12:00:00Z],
      failure_code: code,
      repair_action: repair,
      artifacts: []
    }
  end

  test "renders the Swedish message for each verifier failure code" do
    cases = [
      {:slot_pinned, "fastlåst"},
      {:servings_missing, "saknade portioner"},
      {:skip_not_explicit, "hoppas över"},
      {:leftover_no_source, "göra rester"},
      {:dietary_violation, "passade inte hushållets"}
    ]

    for {code, fragment} <- cases do
      html = render_component(ReceiptLive, id: "r", run: base_failed(code))
      assert html =~ fragment, "expected #{code} message to contain #{inspect(fragment)}"
    end
  end

  test "renders an Edit-the-plan link when repair_action is {:edit_plan, slots}" do
    html =
      render_component(ReceiptLive,
        id: "r",
        run: base_failed(:slot_pinned, {:edit_plan, ["mon_dinner"]})
      )

    assert html =~ ~s(href="/plan?focus=mon_dinner")
  end

  test "renders no edit link when repair_action is nil" do
    html = render_component(ReceiptLive, id: "r", run: base_failed(:internal_error, nil))
    refute html =~ "focus="
  end

  test "renders quiet line for Reverted" do
    reverted = %KitchenRun{
      status: :reverted,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      reverted_at: ~U[2026-06-02 12:01:00Z],
      artifacts: []
    }

    html = render_component(ReceiptLive, id: "r", run: reverted)
    assert html =~ "Återställd"
  end

  defp applied_with_events(events) do
    diff = %PlanDiff{plan_stream_id: "plan-1", week_start: ~D[2026-06-01], events: events}

    %KitchenRun{
      status: :applied,
      id: "run-x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      artifacts: [diff]
    }
  end

  test "Applied renders a named line for a swapped recipe with the day" do
    events = [
      %{
        slot_key: "sat_dinner",
        event_type: "RecipeSwapped",
        payload: %{"label" => "Ugnsraggmunk", "to_slot_key" => "sat_dinner"},
        rationale: ["x"]
      }
    ]

    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Ugnsraggmunk"
    assert html =~ "Lördag"
  end

  test "Applied renders a day-only line for a skip (no recipe name)" do
    events = [
      %{slot_key: "sun_dinner", event_type: "MealSkipped", payload: %{}, rationale: ["x"]}
    ]

    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Hoppade över"
    assert html =~ "Söndag"
  end

  test "Applied renders an added recipe line" do
    events = [
      %{
        slot_key: "mon_dinner",
        event_type: "RecipeAssigned",
        payload: %{"label" => "Roast chicken", "recipe_id" => 1, "servings" => 4},
        rationale: ["x"]
      }
    ]

    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "La till"
    assert html =~ "Roast chicken"
    assert html =~ "Måndag"
  end

  test "Applied renders multiple lines, one per change" do
    events = [
      %{
        slot_key: "sat_dinner",
        event_type: "RecipeSwapped",
        payload: %{"label" => "Ugnsraggmunk", "to_slot_key" => "sat_dinner"},
        rationale: ["x"]
      },
      %{slot_key: "sun_dinner", event_type: "MealSkipped", payload: %{}, rationale: ["y"]}
    ]

    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Ugnsraggmunk"
    assert html =~ "Söndag"
    assert length(Regex.scan(~r/<li/, html)) == 2
  end

  test "Applied with an added change but nil label falls back to day-only phrasing" do
    events = [
      %{
        slot_key: "mon_dinner",
        event_type: "RecipeAssigned",
        payload: %{"recipe_id" => 1, "servings" => 4},
        rationale: ["x"]
      }
    ]

    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "La till en måltid"
    assert html =~ "Måndag"
    refute html =~ "nil"
  end

  test "Applied with no PlanDiff events renders a No changes line" do
    html = render_component(ReceiptLive, id: "r", run: applied_with_events([]))
    assert html =~ "Inga ändringar"
  end
end
