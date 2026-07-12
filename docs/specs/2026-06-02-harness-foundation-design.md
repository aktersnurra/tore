# Harness Foundation Design

> First implementation sub-spec under SPEC.md §Agent Harness Layer. Lands the
> load-bearing primitives every later harness sub-spec depends on: the `Run`
> aggregate (Decider), the `RunArtifact` ADT, the `Orchestrator`, the
> per-household `Projector`, and the run-receipt LiveComponent.

## Status

- **Date:** 2026-06-02
- **Under:** SPEC.md §A (Agent Harness Layer); UI_SPEC.md §7.1 (run receipt) and §7.2 (thinking state).
- **Companion sub-specs (future):** `verifiers_v1`, `capsules_v1`, `resolver_handles`, `risk_tiers`, `kitchen_skills`, `rename_chat_to_capture`, then one per remaining run kind.
- **Disciplines applied:** Decider pattern (already used by `Tore.Planning` and `Tore.Groceries`), type-driven design (illegal states unrepresentable), Tiger naming (verb-first, no `get_*`/`fetch_*` drift), S3-backed payloads where artifacts carry image data.

## §1 — Architecture goals

The Run aggregate is **event-sourced**. The lifecycle is not a sequence of context-API calls (`start`, `transition`, `persist`) — it is a stream of events folded into the current state. Decide what happened by reading the event log; you cannot get to an invalid state because invalid commands never produce events.

The Run state is a **closed sum type**. Each lifecycle phase carries exactly the fields valid in that phase: a `Failed` state always carries `failure_user_message`; a `Draft` state cannot carry a `phase`. Pattern matching on the variant gives you the fields with no `nil` ceremony and no defensive guards.

Reads are served from an **in-memory projection per household**, supervised. The projector subscribes to the household's run-event broadcasts and updates an ETS-backed lookup table. UI processes ask the projector for the latest run on a surface; they never fold events directly. On boot or crash, the projector rebuilds by replaying open runs only (`Draft | Running | NeedsUser`); closed runs (`Applied | Failed | Reverted`) are projected on demand from the event store.

**Artifacts** are a closed ADT. The behaviour `Tore.Harness.Artifact` has five callbacks; the `Artifact.Registry` is a compile-time map of kind-strings to modules. Adding a kind is one registry entry + one module. The compiler enforces that every registered kind implements the behaviour fully.

**Image-carrying artifacts** (future `RecipeProposal`, `CostEntry` with receipt photo) write the image to Garage S3 via `Tore.Storage` and persist only the S3 key on the artifact. This sub-spec ships no image-carrying artifacts but establishes the contract: an artifact's `to_json` never inlines binary data.

**Non-goals.** Verifiers, capsules, resolver handles, risk tiers, Kitchen Skills, module renames, and run kinds other than `:planner_command_run` are deferred. The `Tore.Chat.SystemPrompt.build/0` call remains in place for the orchestrator's system-prompt step until `capsules_v1`.

## §2 — Events, commands, and state

The Run aggregate is a Decider:

```elixir
@callback decide(Command.t(), State.t()) :: {:ok, [Event.t()]} | {:error, term()}
@callback evolve(State.t(), Event.t()) :: State.t()
```

This matches `Tore.Planning.Decider` and `Tore.Groceries.Decider`. `Tore.EventStore.load/2` already folds an event stream through a decider; the Run aggregate plugs into the existing event store with `stream_type: "run"`.

### §2.1 — Events

Events are the only thing persisted. Each event carries minimum data; rich state is rebuilt by folding.

```elixir
defmodule Tore.Harness.Run.Events do
  defmodule Opened, do: defstruct([
    :stream_id,
    :household_id,
    :kind,
    :surface,
    :started_by,
    :user_id,
    :input,
    :opened_at
  ])

  defmodule PhaseEntered, do: defstruct([:phase, :at])
    # phase ∈ ~w[gathering_context proposing verifying]a

  defmodule ToolStepRecorded, do: defstruct([
    :step_index,
    :step_kind,                # :tool_calls | :tool_result | :message
    :payload,                  # opaque map; the agent's trace entry
    :ai_operation_id
  ])

  defmodule ArtifactAdded, do: defstruct([:artifact])
    # artifact is a struct implementing Tore.Harness.Artifact behaviour

  defmodule ModelUsageObserved, do: defstruct([
    :prompt_tokens,
    :completion_tokens,
    :cost_usd
  ])

  defmodule QuestionRaised, do: defstruct([:question, :at])
  defmodule QuestionAnswered, do: defstruct([:answer, :at])

  defmodule Committed, do: defstruct([:at])
  defmodule FailureRecorded, do: defstruct([
    :code,                     # atom, e.g. :slot_locked
    :user_message,             # short user-facing string
    :repair_action,            # optional follow-up dispatch shape
    :at
  ])
  defmodule Reverted, do: defstruct([:at])

  @type t ::
          %Opened{}
          | %PhaseEntered{}
          | %ToolStepRecorded{}
          | %ArtifactAdded{}
          | %ModelUsageObserved{}
          | %QuestionRaised{}
          | %QuestionAnswered{}
          | %Committed{}
          | %FailureRecorded{}
          | %Reverted{}
end
```

### §2.2 — Commands

Commands are intents. The decider accepts them only in the states where they make sense; mismatched (command, state) pairs return `{:error, reason}`.

```elixir
defmodule Tore.Harness.Run.Commands do
  defmodule Open, do: defstruct([
    :household_id,
    :kind,
    :surface,
    :started_by,
    :user_id,
    :input
  ])

  defmodule EnterPhase, do: defstruct([:phase])
  defmodule RecordToolStep, do: defstruct([:step_index, :step_kind, :payload, :ai_operation_id])
  defmodule AddArtifact, do: defstruct([:artifact])
  defmodule ObserveModelUsage, do: defstruct([:prompt_tokens, :completion_tokens, :cost_usd])
  defmodule RaiseQuestion, do: defstruct([:question])
  defmodule AnswerQuestion, do: defstruct([:answer])
  defmodule Commit, do: defstruct([])
  defmodule RecordFailure, do: defstruct([:code, :user_message, :repair_action])
  defmodule Revert, do: defstruct([])

  @type t ::
          %Open{} | %EnterPhase{} | %RecordToolStep{} | %AddArtifact{}
          | %ObserveModelUsage{} | %RaiseQuestion{} | %AnswerQuestion{}
          | %Commit{} | %RecordFailure{} | %Revert{}
end
```

### §2.3 — State

State is a closed sum type. Each variant carries exactly the fields valid in its phase. This is the load-bearing type-driven decision: there is no single `Run` struct with a `status` atom and a sea of nullable fields.

```elixir
defmodule Tore.Harness.Run.State do
  alias Tore.Harness.Run.{Event, Artifact}

  defmodule Draft do
    @enforce_keys [:stream_id]
    defstruct [:stream_id]
  end

  defmodule Running do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :phase, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :phase, :tool_trace, :artifacts, :model_usage
    ]
    @type t :: %__MODULE__{
            phase: :gathering_context | :proposing | :verifying,
            tool_trace: [map()],
            artifacts: [Artifact.t()],
            model_usage: %{prompt_tokens: non_neg_integer(),
                           completion_tokens: non_neg_integer(),
                           cost_usd: Decimal.t()}
          }
  end

  defmodule NeedsUser do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :question, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :question, :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Applied do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :committed_at, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :committed_at, :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Failed do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :failed_at,
      :failure_code, :failure_user_message, :failure_repair_action,
      :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :failed_at,
      :failure_code, :failure_user_message, :failure_repair_action,
      :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Reverted do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :reverted_at, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :reverted_at, :tool_trace, :artifacts, :model_usage
    ]
  end

  @type t :: Draft.t() | Running.t() | NeedsUser.t() | Applied.t() | Failed.t() | Reverted.t()

  @spec empty(String.t()) :: Draft.t()
  def empty(stream_id), do: %Draft{stream_id: stream_id}
end
```

The `@enforce_keys` ensure that any variant constructed from outside the decider has all required fields. A `Failed` without a `failure_user_message` fails to construct; a `Running` without a `phase` fails to construct.

### §2.4 — `decide/2` and `evolve/2`

The decider is the pattern-matched embodiment of the state machine. Each `(command, state)` pair is one clause. Mismatches fall through to a single catch-all that returns `{:error, {:invalid_for_state, command_kind, state_kind}}`.

```elixir
defmodule Tore.Harness.Run.Decider do
  alias Tore.Harness.Run.{Commands, Events, State}

  @spec decide(Commands.t(), State.t()) :: {:ok, [Events.t()]} | {:error, term()}

  def decide(%Commands.Open{} = c, %State.Draft{stream_id: sid}) do
    {:ok, [%Events.Opened{
      stream_id: sid,
      household_id: c.household_id,
      kind: c.kind,
      surface: c.surface,
      started_by: c.started_by,
      user_id: c.user_id,
      input: c.input,
      opened_at: DateTime.utc_now()
    }]}
  end

  def decide(%Commands.EnterPhase{phase: p}, %State.Running{phase: p}), do: {:ok, []}
  def decide(%Commands.EnterPhase{phase: p}, %State.Running{}),
    do: {:ok, [%Events.PhaseEntered{phase: p, at: DateTime.utc_now()}]}

  def decide(%Commands.RecordToolStep{} = c, %State.Running{}) do
    {:ok, [%Events.ToolStepRecorded{
      step_index: c.step_index,
      step_kind: c.step_kind,
      payload: c.payload,
      ai_operation_id: c.ai_operation_id
    }]}
  end

  def decide(%Commands.AddArtifact{artifact: a}, %State.Running{}) do
    if Tore.Harness.Artifact.is_rationale_complete(a) do
      {:ok, [%Events.ArtifactAdded{artifact: a}]}
    else
      {:error, :rationale_incomplete}
    end
  end

  def decide(%Commands.ObserveModelUsage{} = c, %State.Running{}) do
    {:ok, [%Events.ModelUsageObserved{
      prompt_tokens: c.prompt_tokens,
      completion_tokens: c.completion_tokens,
      cost_usd: c.cost_usd
    }]}
  end

  def decide(%Commands.RaiseQuestion{question: q}, %State.Running{}),
    do: {:ok, [%Events.QuestionRaised{question: q, at: DateTime.utc_now()}]}

  def decide(%Commands.AnswerQuestion{answer: a}, %State.NeedsUser{}),
    do: {:ok, [%Events.QuestionAnswered{answer: a, at: DateTime.utc_now()}]}

  def decide(%Commands.Commit{}, %State.Running{}),
    do: {:ok, [%Events.Committed{at: DateTime.utc_now()}]}

  def decide(%Commands.RecordFailure{} = c, %State.Running{}) do
    {:ok, [%Events.FailureRecorded{
      code: c.code,
      user_message: c.user_message,
      repair_action: c.repair_action,
      at: DateTime.utc_now()
    }]}
  end

  def decide(%Commands.Revert{}, %State.Applied{}),
    do: {:ok, [%Events.Reverted{at: DateTime.utc_now()}]}

  def decide(command, state),
    do: {:error, {:invalid_for_state, command.__struct__, state.__struct__}}

  @spec evolve(State.t(), Events.t()) :: State.t()

  def evolve(%State.Draft{stream_id: sid}, %Events.Opened{} = e) do
    %State.Running{
      stream_id: sid,
      household_id: e.household_id,
      kind: e.kind,
      surface: e.surface,
      started_by: e.started_by,
      user_id: e.user_id,
      input: e.input,
      opened_at: e.opened_at,
      phase: :gathering_context,
      tool_trace: [],
      artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
  end

  def evolve(%State.Running{} = s, %Events.PhaseEntered{phase: p}),
    do: %{s | phase: p}

  def evolve(%State.Running{tool_trace: t} = s, %Events.ToolStepRecorded{} = e),
    do: %{s | tool_trace: t ++ [step_to_entry(e)]}

  def evolve(%State.Running{artifacts: a} = s, %Events.ArtifactAdded{artifact: art}),
    do: %{s | artifacts: a ++ [art]}

  def evolve(%State.Running{model_usage: m} = s, %Events.ModelUsageObserved{} = e),
    do: %{s | model_usage: %{
                prompt_tokens: m.prompt_tokens + e.prompt_tokens,
                completion_tokens: m.completion_tokens + e.completion_tokens,
                cost_usd: Decimal.add(m.cost_usd, e.cost_usd)
              }}

  def evolve(%State.Running{} = s, %Events.QuestionRaised{question: q}),
    do: to_needs_user(s, q)

  def evolve(%State.NeedsUser{} = s, %Events.QuestionAnswered{}),
    do: to_running(s)

  def evolve(%State.Running{} = s, %Events.Committed{at: at}),
    do: to_applied(s, at)

  def evolve(%State.Running{} = s, %Events.FailureRecorded{} = e),
    do: to_failed(s, e)

  def evolve(%State.Applied{} = s, %Events.Reverted{at: at}),
    do: to_reverted(s, at)

  # to_needs_user/2, to_running/1, to_applied/2, to_failed/2, to_reverted/2 are
  # the variant-transition constructors. Each is a one-liner that copies the
  # carried fields and adds/drops the variant-specific ones.
end
```

The decider has no side effects, no DB, no time besides `DateTime.utc_now/0` (lifted from the existing decider precedent). Pure transitions over an ADT.

## §3 — `Tore.Harness.Run`

The aggregate's public surface. Tiger naming throughout.

```elixir
defmodule Tore.Harness.Run do
  alias Tore.Harness.Run.{Decider, State}
  alias Tore.EventStore

  @stream_type "run"

  @spec load(String.t()) :: {:ok, State.t()}
  def load(stream_id), do: EventStore.load(stream_id, Decider)

  @spec decide(Commands.t(), State.t()) :: {:ok, [Events.t()]} | {:error, term()}
  defdelegate decide(command, state), to: Decider

  @spec evolve(State.t(), Events.t()) :: State.t()
  defdelegate evolve(state, event), to: Decider

  @spec append(String.t(), [Events.t()], map()) :: :ok
  def append(stream_id, events, metadata \\ %{})
    # Persists events; broadcasts {:run_event, stream_id, event}
    # on "harness:household:#{household_id}".

  @spec next_stream_id() :: String.t()
  def next_stream_id, do: "run-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
end
```

That is the entire surface. No `start_run`, no `transition`, no `persist_artifact`. Callers compose `load` → `decide` → `append`, and `evolve` is automatic via the next `load`.

The convenience pattern (`run/3`: decide + append in one call) is left to the caller — typically the `Orchestrator` (§5). The Decider precedent in `Tore.Planning` is the same.

## §4 — `Tore.Harness.Artifact`

A behaviour with a closed registry. Artifacts are values; the registry is a compile-time map.

```elixir
defmodule Tore.Harness.Artifact do
  @type kind :: String.t()
  @type t :: struct()

  @callback kind() :: kind()
  @callback to_json(t()) :: map()
  @callback from_json(map()) :: t()
  @callback summary(t()) :: %{counts: %{atom() => non_neg_integer()},
                              text_fallback: String.t()}
  @callback is_rationale_complete(t()) :: boolean()

  @spec is_rationale_complete(t()) :: boolean()
  def is_rationale_complete(%mod{} = artifact), do: mod.is_rationale_complete(artifact)

  @spec summary(t()) :: map()
  def summary(%mod{} = artifact), do: mod.summary(artifact)
end

defmodule Tore.Harness.Artifact.Registry do
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}

  @registry %{
    "PlanDiff" => PlanDiff,
    "RunSummary" => RunSummary
  }

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(kind), do: Map.fetch(@registry, kind)

  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@registry)

  @spec modules() :: [module()]
  def modules, do: Map.values(@registry)
end
```

### §4.1 — `PlanDiff`

Two layers, as decided: `events` authoritative, `summarise/1` deterministic projection.

```elixir
defmodule Tore.Harness.Artifact.PlanDiff do
  @behaviour Tore.Harness.Artifact

  @type event_entry :: %{
          slot_key: String.t(),
          event_type: String.t(),
          payload: map(),
          rationale: [String.t()]
        }

  @type rollup_change :: :added | :swapped | :skipped | :leftover | :removed

  @type rollup_entry :: %{
          slot_key: String.t(),
          change: rollup_change(),
          label: String.t(),
          rationale: [String.t()]
        }

  @enforce_keys [:plan_stream_id, :week_start, :events]
  defstruct [:plan_stream_id, :week_start, :events]

  @type t :: %__MODULE__{
          plan_stream_id: String.t(),
          week_start: Date.t(),
          events: [event_entry()]
        }

  @impl true
  def kind, do: "PlanDiff"

  @spec summarise(t()) :: [rollup_entry()]
  def summarise(%__MODULE__{events: events})

  @impl true
  def summary(%__MODULE__{} = diff) do
    rollup = summarise(diff)
    counts = count_changes(rollup)
    %{counts: counts, text_fallback: text_from_counts(counts)}
  end

  @impl true
  def is_rationale_complete(%__MODULE__{events: events}),
    do: Enum.all?(events, fn e -> e.rationale != [] end)

  @impl true
  def to_json(%__MODULE__{} = diff)
  @impl true
  def from_json(map)
end
```

`summarise/1` folds the event sequence per slot into a single final-state rollup entry. Multiple events on the same slot collapse; the rationales accumulate.

### §4.2 — `RunSummary`

```elixir
defmodule Tore.Harness.Artifact.RunSummary do
  @behaviour Tore.Harness.Artifact

  @enforce_keys [:counts, :outcome]
  defstruct [:counts, :outcome]

  @type outcome :: :applied | :needs_user | :failed

  @type t :: %__MODULE__{
          counts: %{atom() => non_neg_integer()},
          outcome: outcome()
        }

  @impl true
  def kind, do: "RunSummary"

  @spec from_artifacts([Artifact.t()], outcome()) :: t()
  def from_artifacts(domain_artifacts, outcome)

  @impl true
  def summary(%__MODULE__{counts: c, outcome: o}),
    do: %{counts: c, text_fallback: text_for(c, o)}

  @impl true
  def is_rationale_complete(_), do: true
  # Derived; the rationale check happens on the domain artifacts it summarises.

  @impl true
  def to_json(%__MODULE__{} = s)
  @impl true
  def from_json(map)
end
```

### §4.3 — S3 payload contract

This sub-spec ships no image-carrying artifacts, but the rule is established now so every future artifact obeys it:

- An artifact may carry an S3 key (string) but never raw image bytes.
- The orchestrator writes the image to `Tore.Storage` before constructing the artifact; the key is what gets serialised.
- `Tore.Storage` already wraps Garage S3 with bucket constants and a behaviour-shaped adapter; future artifacts use `Tore.Storage.put/3` and `Tore.Storage.url/2`.

## §5 — `Tore.Harness.Orchestrator`

The pure-function driver. Takes a command kind + input, walks the Decider, returns the final state. No `GenServer`. No state of its own.

```elixir
defmodule Tore.Harness.Orchestrator do
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}

  @spec dispatch(atom(), map()) :: {:ok, State.t()} | {:error, term()}

  def dispatch(:planner_command_run, %{
        household_id: hh,
        user_id: uid,
        command: text,
        plan_stream_id: psid,
        week_start: ws
      }) do
    stream_id = Run.next_stream_id()

    with {:ok, []}      <- {:ok, []},                          # marker
         {:ok, state}   <- open_run(stream_id, hh, uid, text, psid, ws, :plan),
         {:ok, state}   <- enter(state, :gathering_context),
         {:ok, prompt}  <- build_system_prompt(),
         {:ok, state}   <- enter(state, :proposing),
         {:ok, loop}    <- run_planner_loop(prompt, text, state),
         {:ok, state}   <- absorb_loop(state, loop),
         {:ok, state}   <- enter(state, :verifying),
         {:ok, state}   <- close(state, loop) do
      {:ok, state}
    end
  end

  defp open_run(sid, hh, uid, text, psid, ws, surface) do
    cmd = %Commands.Open{
      household_id: hh,
      user_id: uid,
      kind: "planner_command_run",
      surface: surface,
      started_by: "user",
      input: %{command: text, plan_stream_id: psid, week_start: ws}
    }
    apply_command(sid, cmd)
  end

  defp enter(state, phase) do
    apply_command(state.stream_id, %Commands.EnterPhase{phase: phase}, state)
  end

  defp apply_command(stream_id, command, state \\ nil) do
    state = state || elem(Run.load(stream_id), 1)

    with {:ok, events} <- Run.decide(command, state),
         :ok           <- Run.append(stream_id, events),
         new_state     <- Enum.reduce(events, state, &Run.evolve(&2, &1)) do
      {:ok, new_state}
    end
  end

  # absorb_loop/2 turns the agent's tool_trace + usage into a sequence of
  # RecordToolStep + ObserveModelUsage commands, each appended.

  # close/2 inspects the loop result:
  #   {:message, _}   → AddArtifact(PlanDiff) + AddArtifact(RunSummary) + Commit
  #   {:question, q}  → RaiseQuestion(q)
  #   {:capped, _}    → AddArtifact(RunSummary outcome: :applied) + Commit
  #   {:error, r}     → RecordFailure(code: ..., user_message: ..., repair_action: nil)
end
```

The orchestrator never touches `Repo` directly. It calls `Run.decide` / `Run.append`; the event store does the IO. `Tore.Chat.SystemPrompt.build/0` stays until `capsules_v1`.

`apply_command/3` is the workhorse: load (or carry) state, decide, append, evolve. Future run kinds reuse the same primitive.

## §6 — `Tore.Harness.Projector`

One supervised `GenServer` per household. Subscribes to `"harness:household:#{hh_id}"`. Maintains an ETS-backed lookup keyed by `(:household_id, :surface) → stream_id` for the latest run on each surface, plus `(:household_id, :stream_id) → State.t()` for the full state of open runs.

```elixir
defmodule Tore.Harness.Projector do
  use GenServer
  alias Tore.Harness.Run

  @spec latest_on_surface(household_id :: integer(), surface :: atom()) :: Run.State.t() | nil
  def latest_on_surface(household_id, surface)

  @spec lookup(household_id :: integer(), stream_id :: String.t()) :: Run.State.t() | nil
  def lookup(household_id, stream_id)
end
```

State is a `%Projector{household_id, table: :ets.tid()}` struct. On boot, the projector reads the event store for streams of type `"run"` where the projected state is `Draft | Running | NeedsUser` (open runs), folds each, and populates ETS. Closed runs are projected lazily on `lookup/2`.

Supervised by `Tore.Harness.ProjectorSupervisor` with `Registry` lookup keyed by `household_id`. One process per household; crash recovery is trivial because the event store is the truth.

PubSub broadcasts of `{:run_event, stream_id, event}` from `Run.append/3` are handled by the projector to update its ETS table; the projector then re-broadcasts `{:run_state_changed, stream_id, new_state}` on the same topic, which LiveViews subscribe to.

LiveViews **never** call `Run.load/1`. They call `Projector.latest_on_surface/2` and subscribe to the household topic. Cheap reads, no per-render fold.

## §7 — `Tore.LLM.PlannerAgent` refactor

The agent loses persistence, correlation-ID generation, and the structured return shape. It becomes a pure function.

```elixir
defmodule Tore.LLM.PlannerAgent do
  @spec run(system_prompt :: String.t(), user_text :: String.t(), ctx :: map(), opts :: keyword()) ::
          {:ok, loop_outcome()} | {:error, term()}

  @type loop_outcome :: %{
          result: {:message, String.t()}
                | {:question, String.t()}
                | {:capped, String.t()},
          tool_trace: [trace_step()],
          usage_per_step: [usage()]
        }

  @type trace_step :: %{
          step_index: non_neg_integer(),
          step_kind: :tool_calls | :tool_result | :message,
          payload: map()
        }

  @type usage :: %{prompt_tokens: non_neg_integer(),
                   completion_tokens: non_neg_integer(),
                   cost_usd: Decimal.t()}
end
```

The agent still:

- Builds tools via `PlannerTools.all/0`.
- Drives the 6 round-trip / 12 action-call caps.
- Calls `@llm.chat_with_tools/4`.
- Builds the OpenAI message history correctly (one assistant turn per round, tool messages after).
- Handles `ask_user` as terminal.

The agent **does not** know about runs, `AiOperations`, or system-prompt construction. The orchestrator passes everything in.

For each loop iteration, the orchestrator persists one `AiOperations` row (with `kitchen_run_id` FK populated — schema migration below) **and** issues a `RecordToolStep` command linking the AI operation id. The `tool_trace` field on the `Running` state is fed by these events.

### §7.1 — `AiOperations` FK migration

```elixir
def up do
  execute("DELETE FROM ai_operations")

  alter table(:ai_operations) do
    add :run_stream_id, :string, null: false
    remove :correlation_id
  end

  drop_if_exists unique_index(:ai_operations, [:correlation_id, :step_index])
  create unique_index(:ai_operations, [:run_stream_id, :step_index])
end

def down do
  raise Ecto.MigrationError, "irreversible — restore from backup if needed"
end
```

The FK target is the **stream id**, not a synthetic integer. The Run aggregate's id *is* the stream id; aligning `ai_operations` with that avoids a synthetic-key indirection. The `ai_operations` table holds the audit log; the events table holds the harness truth.

`Tore.AiOperations.AiOperation` schema:

- Remove `correlation_id`.
- Add `run_stream_id :: String.t()`.
- `belongs_to` annotation is not added (stream_ids are not integer FKs; the join is logical).
- `Tore.AiOperations.list_by_correlation/1` renamed to `list_for_run/1`, accepting a stream_id string.

### §7.2 — `PlannerLive` consumes the projector

```elixir
def mount(_, _, socket) do
  household_id = socket.assigns.current_user.household_id

  if connected?(socket) do
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{household_id}")
  end

  latest = Tore.Harness.Projector.latest_on_surface(household_id, :plan)

  {:ok, assign(socket, current_run: latest, quick_loading: false)}
end

def handle_event("quick_command", %{"command" => text}, socket) when text != "" do
  pid = self()
  ctx = build_dispatch_ctx(socket, text)

  Task.start(fn ->
    result = Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)
    send(pid, {:run_dispatched, result})
  end)

  {:noreply, assign(socket, quick_loading: true)}
end

def handle_info({:run_dispatched, {:ok, state}}, socket) do
  {:noreply, assign(socket, current_run: state, quick_loading: false)}
end

def handle_info({:run_dispatched, {:error, _}}, socket) do
  {:noreply, assign(socket, quick_loading: false)}
end

def handle_info({:run_state_changed, _stream_id, state}, socket) do
  if Map.get(socket.assigns.current_run || %{}, :stream_id) == state.stream_id do
    {:noreply, assign(socket, current_run: state)}
  else
    {:noreply, socket}
  end
end
```

The old `quick_reply` assign and its `%{kind: :message | :question | :error}` shape are deleted. The receipt component reads `current_run` directly.

## §8 — Run-receipt LiveComponent

`lib/tore_web/components/receipt_live.ex`. A `Phoenix.LiveComponent` owning its own `expanded?` state.

```elixir
defmodule ToreWeb.Components.ReceiptLive do
  use ToreWeb, :live_component

  alias Tore.Harness.Run.State
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}

  attr :run, :map, required: true   # State.t()
  attr :on_undo, :string, default: "undo_run"
  attr :on_dismiss, :string, default: "dismiss_run"

  def render(assigns)
end
```

The component pattern-matches on the run's state variant:

```elixir
defp body(%State.Running{phase: p}, _expanded?), do: phase_label(p)
defp body(%State.NeedsUser{question: q}, _), do: question_label(q)
defp body(%State.Applied{artifacts: arts}, true), do: expanded_artifacts(arts)
defp body(%State.Applied{artifacts: arts}, false), do: collapsed_summary(arts)
defp body(%State.Failed{} = s, _), do: failure_repair(s)
defp body(%State.Reverted{}, _), do: reverted_quiet()
```

No `if`, no `case` on a status atom. The variant pattern-matches give the right fields at the right time; the compiler enforces exhaustiveness when a future state variant is added.

Per-kind header phrasing is a small helper:

```elixir
defp header_for("planner_command_run", %State.Applied{}), do: gettext("Tore adjusted the plan")
defp header_for("planner_command_run", %State.Failed{}),  do: gettext("Tore couldn't update the plan")
```

The receipt LiveComponent reads artifact summaries via the behaviour: `Artifact.summary(art)` returns `%{counts: ..., text_fallback: ...}`. The component never reaches into an artifact's internal shape.

## §9 — Storage

Two persistence shapes:

- **`events` table** (existing). Run events live here with `stream_type: "run"`. No schema migration needed — the table is already polymorphic over stream type.
- **`ai_operations` table** (existing, migrated). The `correlation_id` column is replaced with `run_stream_id` (§7.1).

**No `kitchen_runs` table.** The state is reconstructed by folding the event stream through the Decider. The projector holds in-memory state for fast reads.

This is consistent with the existing `Tore.Planning` and `Tore.Groceries` aggregates: both store events only, neither has a synthetic projection table on disk.

## §10 — Tests

- `test/tore/harness/run/decider_test.exs` — pure tests for `decide/2` and `evolve/2`. Property-style: every valid command sequence produces a valid state; every invalid pair returns the expected error tuple.
- `test/tore/harness/run/state_test.exs` — `@enforce_keys` constructor tests; assert that illegal state construction raises at compile time (one or two `defstruct` invariants tested explicitly).
- `test/tore/harness/artifact_test.exs` — registry lookup, behaviour contract enforcement.
- `test/tore/harness/artifact/plan_diff_test.exs` — `summarise/1` projection cases (single-event slot, multi-event slot collapsing, mixed kinds).
- `test/tore/harness/artifact/run_summary_test.exs` — `from_artifacts/2` count aggregation.
- `test/tore/harness/orchestrator_test.exs` — end-to-end against `Tore.MockLLM`. Drives `dispatch(:planner_command_run, ...)`, asserts the resulting state is `Applied`, asserts `ai_operations` rows exist with `run_stream_id` populated, asserts PubSub broadcasts.
- `test/tore/harness/projector_test.exs` — boot-time replay correctness; surface-keyed lookups; PubSub propagation.
- `test/tore/llm/planner_agent_test.exs` — updated. Agent tests no longer assert on `AiOperations`; they assert on the loop's pure return.
- `test/tore_web/live/planner_live_test.exs` — updated. Asserts `current_run` is populated and the receipt component renders the expected text per state variant.
- `test/tore_web/components/receipt_live_test.exs` — new. `render_component/2` for each state variant.

## §11 — Success criteria

1. `mix compile --force --warnings-as-errors` clean.
2. `mix test` shows no new failures vs the floor as of `587101b6` (the demotion + reconciliation chain).
3. `priv/repo/migrations/<ts>_add_run_stream_id_to_ai_operations.exs` exists and runs cleanly. `mix ecto.reset` from scratch produces a working schema.
4. `Tore.Harness.Run.decide/2` and `evolve/2` are pure: no `Repo`, no `Logger`, no `DateTime.utc_now/0` calls outside the marshalling clauses already isolated in `Decider`.
5. `Tore.Harness.Run.State` variants enforce their key sets via `@enforce_keys`. Constructing a `%State.Failed{}` without `failure_user_message` raises at compile time.
6. `Tore.Harness.Orchestrator.dispatch(:planner_command_run, attrs)` end-to-end against `Tore.MockLLM`: returns `{:ok, %State.Applied{}}`, the event stream contains the expected event sequence, `ai_operations` rows exist with `run_stream_id` populated.
7. `Tore.LLM.PlannerAgent.run/4` is pure: no DB writes, no correlation-ID generation, no `AiOperations.log/1` calls.
8. `Tore.Harness.Projector` is supervised, one per household, boots by replaying open runs only, updates ETS in response to event broadcasts.
9. The receipt LiveComponent renders correctly for each state variant; tests assert per-variant rendering.
10. Manual smoke against real OpenRouter from the planner command bar: typing "skip mon dinner" produces a `run` event stream visible in `iex` via `Tore.EventStore.load(stream_id, Tore.Harness.Run.Decider)`, with the expected event sequence and a final `%State.Applied{}`.
11. `grep -rn "correlation_id" lib/ test/` returns no live-code hits.
12. The previous `quick_reply` assign and its three-shape map are removed from `planner_live.ex` and its tests.

## §12 — Out of scope (with future sub-spec names)

| Deferred | Future sub-spec |
|---|---|
| Verifier checklist; verifier-failure UI; rationale enforcement at the verifier level | `verifiers_v1` |
| Typed context capsules; deletion of `Tore.Chat.SystemPrompt.build/0` | `capsules_v1` |
| Resolver tools and typed handles on action tools | `resolver_handles` |
| Risk tier classification; Tier 3 confirm modal | `risk_tiers` |
| Kitchen Skills catalog and surface chips | `kitchen_skills` |
| Module rename: `Tore.Chat → Tore.Capture`, route renames, gettext updates | `rename_chat_to_capture` |
| Run kinds beyond `:planner_command_run` | One sub-spec per kind (see SPEC.md §The Six LLM-Native Features) |
| Image-carrying artifacts (`RecipeProposal`, `CostEntry` with photo) and the `Tore.Storage`-keyed payload flow | First of these is `receipt_ingestion_run` |
| Full Today / Plan / Shop / Capture page redesigns | Per-page UI sub-specs |
| Postgres migration | Future `postgres_migration` if and when needed |

Each future sub-spec inherits this design's contracts: the Run aggregate's Decider, the Artifact behaviour, the Orchestrator entry point, the Projector lookup surface, the S3-keyed payload rule.
