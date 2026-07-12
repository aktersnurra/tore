# Phase 7 — Family Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two-tier family memory: per-record insights table with weekly LLM synthesis (Tier 1) + live this-week context from event store (Tier 2). Both injected into chat system prompt.

**Architecture:** `family_insights` table stores LLM-generated observations. Weekly Quantum job synthesises insights from planning events. `WeekContext.build/1` generates Tier 2 cheaply from event store. Both flow into `SystemPrompt.build/0`.

**Tech Stack:** Elixir, Phoenix, SQLite/Ecto, Mox for LLM (`Tore.MockLLM`), Quantum for scheduling

---

## Task 1 — `family_insights` migration, schema, and `Tore.Family` context

**Files to create/edit:**
- `priv/repo/migrations/20260529000001_create_family_insights.exs` (new)
- `lib/tore/family/family_insight.ex` (new)
- `lib/tore/family.ex` (new)
- `test/tore/family_insights_test.exs` (new)

### Steps

- [ ] Create migration `priv/repo/migrations/20260529000001_create_family_insights.exs`:

```elixir
defmodule Tore.Repo.Migrations.CreateFamilyInsights do
  use Ecto.Migration

  def change do
    create table(:family_insights) do
      add :kind, :string, null: false
      add :body, :text, null: false
      add :confidence, :float, null: false, default: 0.5
      add :evidence, :text
      add :status, :string, null: false, default: "active"
      add :generated_at, :utc_datetime, null: false
      timestamps(updated_at: false)
    end

    create index(:family_insights, [:status])
  end
end
```

- [ ] Create `lib/tore/family/family_insight.ex`:

```elixir
defmodule Tore.Family.FamilyInsight do
  use Ecto.Schema
  import Ecto.Changeset

  schema "family_insights" do
    field :kind, :string
    field :body, :string
    field :confidence, :float, default: 0.5
    field :evidence, :string
    field :status, :string, default: "active"
    field :generated_at, :utc_datetime
    timestamps(updated_at: false)
  end

  @valid_statuses ~w[active superseded dismissed]
  @valid_kinds ~w[skip_pattern cascade_success time_preference cuisine_fatigue variety_win]

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [:kind, :body, :confidence, :evidence, :status, :generated_at])
    |> validate_required([:kind, :body, :confidence, :generated_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
```

- [ ] Create `lib/tore/family.ex`:

```elixir
defmodule Tore.Family do
  import Ecto.Query
  alias Tore.{Repo, Family.FamilyInsight}

  @spec list_active_insights() :: [FamilyInsight.t()]
  def list_active_insights do
    from(i in FamilyInsight,
      where: i.status == "active",
      order_by: [desc: i.confidence]
    )
    |> Repo.all()
  end

  @spec dismiss_insight(integer()) :: {:ok, FamilyInsight.t()} | {:error, Ecto.Changeset.t()}
  def dismiss_insight(id) do
    Repo.get!(FamilyInsight, id)
    |> FamilyInsight.changeset(%{status: "dismissed"})
    |> Repo.update()
  end

  @spec replace_insights([map()]) :: {:ok, [FamilyInsight.t()]} | {:error, term()}
  def replace_insights(new_insights) when is_list(new_insights) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      from(i in FamilyInsight, where: i.status == "active")
      |> Repo.update_all(set: [status: "superseded"])

      Enum.map(new_insights, fn attrs ->
        %FamilyInsight{}
        |> FamilyInsight.changeset(%{
          kind: attrs.kind,
          body: attrs.body,
          confidence: attrs.confidence,
          evidence: encode_evidence(attrs[:evidence]),
          status: "active",
          generated_at: now
        })
        |> Repo.insert!()
      end)
    end)
  end

  defp encode_evidence(nil), do: nil
  defp encode_evidence(ids) when is_list(ids), do: Jason.encode!(ids)
end
```

- [ ] Create `test/tore/family_insights_test.exs`:

```elixir
defmodule Tore.FamilyInsightsTest do
  use ExUnit.Case, async: true

  alias Tore.Family

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  defp insight_attrs(overrides \\ %{}) do
    Map.merge(
      %{kind: "skip_pattern", body: "Family skips Mondays", confidence: 0.8},
      overrides
    )
  end

  test "list_active_insights returns only active insights sorted by confidence desc" do
    {:ok, _} = Family.replace_insights([insight_attrs(%{confidence: 0.6})])
    {:ok, insights} = Family.replace_insights([
      insight_attrs(%{confidence: 0.9, body: "High confidence"}),
      insight_attrs(%{confidence: 0.4, body: "Low confidence"})
    ])

    active = Family.list_active_insights()
    assert length(active) == 2
    assert hd(active).confidence == 0.9
    assert Enum.all?(active, &(&1.status == "active"))
  end

  test "replace_insights supersedes previous active insights" do
    {:ok, first_batch} = Family.replace_insights([insight_attrs()])
    first_id = hd(first_batch).id

    {:ok, _} = Family.replace_insights([insight_attrs(%{body: "New insight"})])

    import Ecto.Query
    old = Tore.Repo.get!(Tore.Family.FamilyInsight, first_id)
    assert old.status == "superseded"
  end

  test "dismiss_insight marks insight as dismissed" do
    {:ok, [insight]} = Family.replace_insights([insight_attrs()])

    {:ok, dismissed} = Family.dismiss_insight(insight.id)
    assert dismissed.status == "dismissed"
    assert Family.list_active_insights() == []
  end

  test "list_active_insights excludes dismissed insights" do
    {:ok, [insight]} = Family.replace_insights([insight_attrs()])
    Family.dismiss_insight(insight.id)

    assert Family.list_active_insights() == []
  end
end
```

- [ ] Run `mix ecto.migrate` to apply migration
- [ ] Run `mix test test/tore/family_insights_test.exs` — all pass
- [ ] `jj describe -m "feat: family_insights table, FamilyInsight schema, Family context with list/dismiss/replace"`

---

## Task 2 — `synthesise_insights/1` callback in LLM + OpenRouter implementation

**Files to edit:**
- `lib/tore/llm.ex`
- `lib/tore/adapters/open_router.ex`
- `lib/tore/llm/prompts.ex`

**Files to create:**
- `test/tore/adapters/synthesise_insights_test.exs` (new)

### Steps

- [ ] Add callback to `lib/tore/llm.ex` (append after the last `@callback`):

```elixir
@callback synthesise_insights(events_summary :: String.t()) ::
  {:ok, [%{kind: String.t(), body: String.t(), confidence: float(), evidence: [integer()]}]} |
  {:error, term()}
```

- [ ] Add prompt builder to `lib/tore/llm/prompts.ex`:

```elixir
def synthesise_insights(events_summary) do
  system = """
  You are a household cooking analyst. Given a summary of a family's meal planning events
  over the past 4 weeks, extract 3–7 durable observations about their patterns.

  Each insight must have:
  - kind: one of skip_pattern, cascade_success, time_preference, cuisine_fatigue, variety_win
  - body: one concise natural-language sentence (max 20 words), written as a present-tense observation
  - confidence: 0.0–1.0 based on how many events support it
  - evidence: array of integer event IDs that support this observation

  Return JSON only: {"insights": [{"kind": "...", "body": "...", "confidence": 0.0, "evidence": []}]}
  Omit any insight with confidence below 0.3.
  """

  user = "Planning events summary:\n#{events_summary}"
  {system, user}
end
```

- [ ] Add `@impl Tore.LLM` implementation to `lib/tore/adapters/open_router.ex` (after the last `@impl Tore.LLM` block, before `@impl Tore.ImageGen`):

```elixir
@impl Tore.LLM
def synthesise_insights(events_summary) do
  {system, user} = Tore.LLM.Prompts.synthesise_insights(events_summary)

  case chat(system, user) do
    {:ok, %{"insights" => insights}, _usage} when is_list(insights) ->
      parsed =
        Enum.map(insights, fn i ->
          %{
            kind: i["kind"],
            body: i["body"],
            confidence: i["confidence"] || 0.5,
            evidence: i["evidence"] || []
          }
        end)

      {:ok, parsed}

    {:ok, _, _} ->
      {:error, :invalid_response}

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] Create `test/tore/adapters/synthesise_insights_test.exs`:

```elixir
defmodule Tore.Adapters.SynthesiseInsightsTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "synthesise_insights returns parsed insight list" do
    Tore.MockLLM
    |> expect(:synthesise_insights, fn summary ->
      assert is_binary(summary)

      {:ok,
       [
         %{kind: "skip_pattern", body: "Family skips Mondays often.", confidence: 0.8, evidence: [1, 2]},
         %{kind: "time_preference", body: "Quick meals preferred mid-week.", confidence: 0.6, evidence: [3]}
       ]}
    end)

    {:ok, insights} = Tore.MockLLM.synthesise_insights("Week 1: skipped mon_dinner (id:1)...")
    assert length(insights) == 2
    assert hd(insights).kind == "skip_pattern"
    assert hd(insights).confidence == 0.8
  end

  test "synthesise_insights propagates errors" do
    Tore.MockLLM
    |> expect(:synthesise_insights, fn _summary -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} = Tore.MockLLM.synthesise_insights("summary")
  end
end
```

- [ ] Run `mix test test/tore/adapters/synthesise_insights_test.exs` — all pass
- [ ] `jj describe -m "feat: synthesise_insights/1 LLM callback, OpenRouter impl, prompt"`

---

## Task 3 — `InsightsHandler` — weekly synthesis orchestrator

**Files to create:**
- `lib/tore/handlers/insights_handler.ex` (new)
- `test/tore/handlers/insights_handler_test.exs` (new)

### Steps

- [ ] Create `lib/tore/handlers/insights_handler.ex`:

```elixir
defmodule Tore.Handlers.InsightsHandler do
  import Ecto.Query
  alias Tore.{EventStore, Family}

  @llm Application.compile_env(:tore, :llm_client)

  @doc """
  Load planning events from the last 28 days, format a weighted summary,
  call LLM to synthesise insights, then atomically replace active insights.
  """
  @spec synthesise_weekly() :: {:ok, [Family.FamilyInsight.t()]} | {:error, term()}
  def synthesise_weekly do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-28 * 86_400, :second)
      |> DateTime.to_naive()

    events =
      from(e in EventStore.Event,
        where: e.stream_type == "planning" and e.inserted_at >= ^cutoff,
        order_by: [asc: e.id]
      )
      |> Tore.Repo.all()

    summary = format_events_summary(events)

    with {:ok, insights} <- @llm.synthesise_insights(summary) do
      Family.replace_insights(insights)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Skip events carry the most signal; routine assignments are lower weight.
  @high_weight_types ~w[MealSkipped RecipeRemoved]
  @low_weight_types ~w[RecipeAssigned PlanGenerated]

  defp format_events_summary([]), do: "No planning events in the last 28 days."

  defp format_events_summary(events) do
    lines =
      events
      |> Enum.map(fn e ->
        weight = if e.event_type in @high_weight_types, do: "[HIGH] ", else: ""
        "#{weight}#{e.event_type} (id:#{e.id}) stream:#{e.stream_id} at:#{e.inserted_at} data:#{e.data}"
      end)

    total = length(events)
    high = Enum.count(events, &(&1.event_type in @high_weight_types))

    """
    Planning event summary — last 28 days (#{total} events, #{high} high-signal):

    #{Enum.join(lines, "\n")}
    """
  end
end
```

- [ ] Create `test/tore/handlers/insights_handler_test.exs`:

```elixir
defmodule Tore.Handlers.InsightsHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tore.Handlers.InsightsHandler
  alias Tore.Family

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "synthesise_weekly calls LLM with events summary and saves insights" do
    Tore.MockLLM
    |> expect(:synthesise_insights, fn summary ->
      assert is_binary(summary)

      {:ok,
       [
         %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.75, evidence: []},
         %{kind: "time_preference", body: "Quick meals preferred mid-week.", confidence: 0.6, evidence: []}
       ]}
    end)

    assert {:ok, saved} = InsightsHandler.synthesise_weekly()
    assert length(saved) == 2
    assert hd(saved).status == "active"
    assert length(Family.list_active_insights()) == 2
  end

  test "synthesise_weekly supersedes old insights on re-run" do
    Tore.MockLLM
    |> expect(:synthesise_insights, 2, fn _summary ->
      {:ok, [%{kind: "skip_pattern", body: "Pattern detected.", confidence: 0.7, evidence: []}]}
    end)

    InsightsHandler.synthesise_weekly()
    InsightsHandler.synthesise_weekly()

    assert length(Family.list_active_insights()) == 1
  end

  test "synthesise_weekly returns error when LLM fails" do
    Tore.MockLLM
    |> expect(:synthesise_insights, fn _summary -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} = InsightsHandler.synthesise_weekly()
    assert Family.list_active_insights() == []
  end
end
```

- [ ] Run `mix test test/tore/handlers/insights_handler_test.exs` — all pass
- [ ] `jj describe -m "feat: InsightsHandler — weekly LLM synthesis from planning events"`

---

## Task 4 — Wire InsightsHandler into Quantum scheduler

**Files to edit:**
- `config/config.exs`

### Steps

- [ ] Edit `config/config.exs` — add the Saturday 06:00 job to the Quantum jobs list:

The current jobs block ends at line 70. Add a new entry inside the `jobs` list:

```elixir
{"0 6 * * 6", {Tore.Handlers.InsightsHandler, :synthesise_weekly, []}},
```

The updated jobs list should look like:

```elixir
config :tore, Tore.Scheduler,
  jobs: [
    {"0 3 * * *", {Tore.Deals, :clear_expired, []}},
    {"0 6 * * 6", {Tore.Handlers.InsightsHandler, :synthesise_weekly, []}},
    {"0 8 * * 6", {Tore.Handlers.DealsHandler, :scrape_all, []}},
    {"0 18 * * 6",
     fn ->
       Tore.Handlers.PlanningHandler.generate_plan("plan:current", Date.utc_today())
     end},
    {"30 18 * * 6",
     fn ->
       Tore.Handlers.PrepHandler.generate_guide("plan:current", Date.utc_today())
     end}
  ]
```

- [ ] Verify the scheduler compiles: `mix compile --no-optional-deps`
- [ ] `jj describe -m "feat: register weekly insights synthesis job in Quantum scheduler (Sat 06:00)"`

---

## Task 5 — `WeekContext.build/1` — Tier 2 pure function

**Files to create:**
- `lib/tore/chat/week_context.ex` (new)
- `test/tore/chat/week_context_test.exs` (new)

**Note:** `lib/tore/chat/` directory does not exist yet — create it via the new files.

### Steps

- [ ] Create `lib/tore/chat/week_context.ex`:

```elixir
defmodule Tore.Chat.WeekContext do
  alias Tore.Planning.State

  @days ~w[mon tue wed thu fri sat sun]
  @day_labels %{
    "mon" => "Mon", "tue" => "Tue", "wed" => "Wed",
    "thu" => "Thu", "fri" => "Fri", "sat" => "Sat", "sun" => "Sun"
  }

  @doc """
  Build a compact text summary of the current week's plan state.
  Pure function — no DB access, no LLM.

  Returns a string suitable for injection into a system prompt.
  """
  @spec build(State.t() | nil) :: String.t()
  def build(nil), do: "No meals planned this week."
  def build(%State{slots: slots}) when map_size(slots) == 0, do: "No meals planned this week."

  def build(%State{week_start: week_start, slots: slots}) do
    week_desc =
      if week_start do
        formatted = Calendar.strftime(week_start, "%A %d %b")
        "Week of #{formatted}. "
      else
        ""
      end

    slot_summaries =
      @days
      |> Enum.map(fn day -> {day, Map.get(slots, "#{day}_dinner")} end)
      |> Enum.reject(fn {_day, slot} -> is_nil(slot) end)
      |> Enum.map(fn {day, slot} -> format_slot(@day_labels[day], slot) end)

    if slot_summaries == [] do
      "No meals planned this week."
    else
      "#{week_desc}#{Enum.join(slot_summaries, "; ")}."
    end
  end

  defp format_slot(label, %{skipped: true}), do: "#{label}: skipped"
  defp format_slot(label, %{leftover: true, recipe_id: id}) when not is_nil(id),
    do: "#{label}: leftover (recipe #{id})"
  defp format_slot(label, %{recipe_id: id}) when not is_nil(id),
    do: "#{label}: recipe #{id}"
  defp format_slot(label, _), do: "#{label}: unplanned"
end
```

- [ ] Create `test/tore/chat/week_context_test.exs`:

```elixir
defmodule Tore.Chat.WeekContextTest do
  use ExUnit.Case, async: true

  alias Tore.Chat.WeekContext
  alias Tore.Planning.State

  test "returns fallback for nil state" do
    assert WeekContext.build(nil) == "No meals planned this week."
  end

  test "returns fallback for empty slots" do
    state = %State{slots: %{}}
    assert WeekContext.build(state) == "No meals planned this week."
  end

  test "describes a skipped slot" do
    state = %State{
      week_start: ~D[2026-05-25],
      slots: %{"mon_dinner" => %{skipped: true, recipe_id: nil, leftover: false}}
    }

    result = WeekContext.build(state)
    assert result =~ "Mon: skipped"
  end

  test "describes assigned slot" do
    state = %State{
      week_start: ~D[2026-05-25],
      slots: %{"tue_dinner" => %{recipe_id: 42, skipped: false, leftover: false}}
    }

    result = WeekContext.build(state)
    assert result =~ "Tue: recipe 42"
  end

  test "describes leftover slot" do
    state = %State{
      week_start: ~D[2026-05-25],
      slots: %{"wed_dinner" => %{recipe_id: 7, skipped: false, leftover: true}}
    }

    result = WeekContext.build(state)
    assert result =~ "Wed: leftover (recipe 7)"
  end

  test "full week produces ordered day references" do
    state = %State{
      week_start: ~D[2026-05-25],
      slots: %{
        "mon_dinner" => %{recipe_id: 1, skipped: false, leftover: false},
        "tue_dinner" => %{skipped: true, recipe_id: nil, leftover: false},
        "wed_dinner" => %{recipe_id: 2, skipped: false, leftover: true}
      }
    }

    result = WeekContext.build(state)
    assert result =~ "Mon:"
    assert result =~ "Tue: skipped"
    assert result =~ "Wed: leftover"
    assert result =~ "Week of"
  end
end
```

- [ ] Run `mix test test/tore/chat/week_context_test.exs` — all pass
- [ ] `jj describe -m "feat: WeekContext.build/1 — pure Tier 2 this-week context for system prompt"`

---

## Task 6 — Wire both tiers into `SystemPrompt.build/0`

**Files to create/edit:**
- `lib/tore/chat/system_prompt.ex` (new — the stub currently does not exist; create it)
- `test/tore/chat/system_prompt_test.exs` (new)

**Note:** `grep` confirms there is no `lib/tore/chat/system_prompt.ex` yet. Check the Phase 4 code that references `list_active_insights/0` returning `[]` before writing — run:
```
grep -rn "list_active_insights\|SystemPrompt\|system_prompt" lib/
```
to locate the current stub and adapt.

### Steps

- [ ] Locate the Phase 4 stub that calls `list_active_insights/0`. It likely lives in a LiveView or chat handler. Replace the stub call with `Tore.Family.list_active_insights()`.

- [ ] Create `lib/tore/chat/system_prompt.ex`:

```elixir
defmodule Tore.Chat.SystemPrompt do
  alias Tore.{Family, Handlers.PlanningHandler}
  alias Tore.Chat.WeekContext

  @plan_id "plan:current"
  @max_insights 5

  @doc """
  Build the chat system prompt, injecting:
  - Up to #{@max_insights} active family insights (Tier 1, LLM-synthesised)
  - This week's plan context (Tier 2, pure function)
  """
  @spec build() :: String.t()
  def build do
    insights = Family.list_active_insights() |> Enum.take(@max_insights)
    plan_state = load_plan_state()
    week_context = WeekContext.build(plan_state)

    insights_section = format_insights(insights)

    """
    You are Tore, a warm and practical household cooking assistant.
    You help with meal planning, recipes, shopping, and kitchen logistics.
    Be concise, direct, and friendly. Avoid unnecessary caveats.

    ## What you know about this family
    #{insights_section}

    ## This week
    #{week_context}
    """
    |> String.trim()
  end

  defp load_plan_state do
    case PlanningHandler.load_plan(@plan_id) do
      {:ok, state} -> state
      _ -> nil
    end
  end

  defp format_insights([]) do
    "No patterns observed yet — this is the family's early history with Tore."
  end

  defp format_insights(insights) do
    insights
    |> Enum.map(fn i -> "- #{i.body}" end)
    |> Enum.join("\n")
  end
end
```

- [ ] Create `test/tore/chat/system_prompt_test.exs`:

```elixir
defmodule Tore.Chat.SystemPromptTest do
  use ExUnit.Case, async: false

  alias Tore.{Chat.SystemPrompt, Family}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "build/0 includes fallback when no insights exist" do
    result = SystemPrompt.build()
    assert result =~ "No patterns observed yet"
  end

  test "build/0 includes insight body when active insights exist" do
    {:ok, _} =
      Family.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    result = SystemPrompt.build()
    assert result =~ "Mondays are often skipped."
  end

  test "build/0 limits insights to top 5 by confidence" do
    insights = for i <- 1..8 do
      %{kind: "skip_pattern", body: "Insight number #{i}.", confidence: i / 10, evidence: []}
    end

    Family.replace_insights(insights)

    result = SystemPrompt.build()
    insight_lines = result |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- "))
    assert length(insight_lines) == 5
  end

  test "build/0 includes week context section" do
    result = SystemPrompt.build()
    assert result =~ "## This week"
  end
end
```

- [ ] Run `mix test test/tore/chat/` — all pass
- [ ] Run full suite `mix test` — no regressions
- [ ] `jj describe -m "feat: SystemPrompt.build/0 — inject family insights (Tier 1) and week context (Tier 2)"`

---

## Completion checklist

- [ ] All 6 task commits made with `jj describe -m`
- [ ] `mix test` green (no regressions)
- [ ] `mix compile` clean (no warnings)
- [ ] `Family.list_active_insights/0` and `Family.dismiss_insight/1` exported — satisfies Phase 8 Task 8 dependency
- [ ] Weekly synthesis job registered at `"0 6 * * 6"` in `config/config.exs`
