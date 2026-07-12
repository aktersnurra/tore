# NL Planner — Tool-Calling Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the planner's stub `quick_command` (which round-trips through plain chat) with `PlannerAgent`, a bounded tool-calling loop where the LLM uses six action tools wrapping Decider commands plus four read tools, executes user intents through `PlanningHandler`, and asks for clarification via `ask_user` instead of guessing.

**Architecture:** New LLM behaviour callback `chat_with_tools/4` returns either a final assistant message or a list of tool calls. `Tore.LLM.PlannerAgent` runs the loop: send → model picks tools → app executes via `PlannerTools` → result fed back → repeat until message-or-cap. Tools are pure data: `%Tool{name, description, parameters, kind, run}`. Actions go through `Tore.Handlers.PlanningHandler`; reads go through `Tore.Recipes`, `Tore.Pantry`, `Tore.Deals`. Every iteration logs an `ai_operations` row sharing one `correlation_id`. `PlannerLive.handle_event("quick_command", …)` switches from `ChatHandler.handle_text` to `PlannerAgent.run/3`.

**Tech Stack:** Elixir/Phoenix/LiveView, OpenRouter (existing `Tore.Adapters.OpenRouter`), Req, Mox (`Tore.MockLLM`), Ecto/SQLite, jj for commits.

**Spec reference:** `SPEC.md` §2 ("Natural-Language Commands on the Planner (Tool-Calling Agent)") and §"LLM Interface Conventions" → Pattern B.

**LLM wiring convention (existing):**
- `config :tore, :llm_client, <module>` (prod = `Tore.Adapters.OpenRouter`, test = `Tore.MockLLM`).
- Handlers reference it via `@llm Application.compile_env(:tore, :llm_client)`.
- Mox mock: `Tore.MockLLM` defined in `test/support/mocks.ex`.

---

## File Structure

- Create: `lib/tore/llm/planner_agent.ex` — loop runtime, no LLM specifics.
- Create: `lib/tore/llm/planner_tools.ex` — the 10 tool definitions and their `run` functions.
- Create: `lib/tore/llm/tool.ex` — `%Tool{}` struct and helpers.
- Modify: `lib/tore/llm.ex` — add `chat_with_tools/4` callback.
- Modify: `lib/tore/adapters/open_router.ex` — implement `chat_with_tools/4` against OpenRouter.
- Modify: `lib/tore_web/live/planner_live.ex` — route `quick_command` through `PlannerAgent`; render multi-step result.
- Modify: `lib/tore/ai_operations/ai_operation.ex` — add `step_index`, drop unique constraint on `correlation_id`.
- Migrate: `priv/repo/migrations/<ts>_ai_operations_add_step_index.exs` — drop unique index, add `step_index` integer.
- Create: `test/tore/llm/planner_tools_test.exs`
- Create: `test/tore/llm/planner_agent_test.exs`
- Modify: `test/support/mocks.ex` — Mox stub already covers behaviour; nothing to edit, but referenced in tests.
- Modify: `test/tore_web/live/planner_live_test.exs` — command-bar flow test.

Each file has one responsibility:
- `Tool` is a data struct.
- `PlannerTools` is the catalog (and bridges to `PlanningHandler` / `Recipes` / `Pantry` / `Deals`).
- `PlannerAgent` is loop orchestration only — no tool knowledge, no LLM-vendor knowledge.
- The adapter is the only place that knows OpenRouter's tool-call JSON shape.

---

## Task 1 — Schema migration: drop unique constraint, add step_index

### Files
- Create: `priv/repo/migrations/20260530000010_ai_operations_add_step_index.exs`
- Modify: `lib/tore/ai_operations/ai_operation.ex`
- Modify: `lib/tore/ai_operations.ex`
- Test: `test/tore/ai_operations_test.exs` (add cases)

### Why
The existing `ai_operations.correlation_id` has a `unique_index`. A tool-calling loop produces multiple rows that share one `correlation_id`. We need `(correlation_id, step_index)` to be unique instead.

### Steps

- [ ] **Step 1.1: Write the failing test**

In `test/tore/ai_operations_test.exs`, append:

```elixir
test "logs multiple steps under one correlation_id" do
  cid = "test-cid-#{System.unique_integer([:positive])}"

  assert {:ok, _} =
           Tore.AiOperations.log(%{
             correlation_id: cid,
             kind: "planner_agent.turn",
             step_index: 0,
             payload: "user msg",
             result: "tool_calls"
           })

  assert {:ok, _} =
           Tore.AiOperations.log(%{
             correlation_id: cid,
             kind: "planner_agent.turn",
             step_index: 1,
             payload: "tool result",
             result: "final"
           })

  rows = Tore.AiOperations.list_by_correlation(cid)
  assert length(rows) == 2
  assert Enum.map(rows, & &1.step_index) == [0, 1]
end

test "rejects duplicate (correlation_id, step_index)" do
  cid = "dup-cid-#{System.unique_integer([:positive])}"
  {:ok, _} = Tore.AiOperations.log(%{correlation_id: cid, kind: "k", step_index: 0})

  assert {:error, %Ecto.Changeset{}} =
           Tore.AiOperations.log(%{correlation_id: cid, kind: "k", step_index: 0})
end
```

- [ ] **Step 1.2: Run the test to verify it fails**

Run: `mix test test/tore/ai_operations_test.exs --only line:<line_of_first_new_test>` (or just `mix test test/tore/ai_operations_test.exs`).
Expected: FAIL — schema has no `step_index`, and the second insert with the same `correlation_id` will fail today regardless.

- [ ] **Step 1.3: Write the migration**

Create `priv/repo/migrations/20260530000010_ai_operations_add_step_index.exs`:

```elixir
defmodule Tore.Repo.Migrations.AiOperationsAddStepIndex do
  use Ecto.Migration

  def change do
    alter table(:ai_operations) do
      add :step_index, :integer, null: false, default: 0
    end

    drop_if_exists unique_index(:ai_operations, [:correlation_id])
    create unique_index(:ai_operations, [:correlation_id, :step_index])
  end
end
```

- [ ] **Step 1.4: Update the schema**

Edit `lib/tore/ai_operations/ai_operation.ex` to add `step_index` and adjust the unique_constraint:

```elixir
defmodule Tore.AiOperations.AiOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_operations" do
    field :correlation_id, :string
    field :kind, :string
    field :payload, :string
    field :result, :string
    field :step_index, :integer, default: 0
    field :undo_op_id, :integer
    field :inserted_at, :utc_datetime, autogenerate: false
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:correlation_id, :kind, :payload, :result, :step_index, :undo_op_id])
    |> validate_required([:correlation_id, :kind])
    |> unique_constraint([:correlation_id, :step_index],
         name: :ai_operations_correlation_id_step_index_index)
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
```

- [ ] **Step 1.5: Add `list_by_correlation/1` to the context**

Edit `lib/tore/ai_operations.ex`, append:

```elixir
import Ecto.Query

def list_by_correlation(correlation_id) do
  Tore.Repo.all(
    from o in Tore.AiOperations.AiOperation,
      where: o.correlation_id == ^correlation_id,
      order_by: [asc: o.step_index]
  )
end
```

(If `import Ecto.Query` is already in this file, do not duplicate it.)

- [ ] **Step 1.6: Run migrations and tests**

Run:
```
mix ecto.migrate
mix test test/tore/ai_operations_test.exs
```
Expected: PASS for the two new cases. The existing tests still pass.

- [ ] **Step 1.7: Commit**

```
jj describe -m "feat(ai_operations): allow multi-step logs under one correlation_id

Drops unique constraint on correlation_id, adds step_index, and a new
unique index on (correlation_id, step_index). PlannerAgent (next) needs
to log every loop iteration under a shared correlation id."
jj new
```

---

## Task 2 — Tool struct

### Files
- Create: `lib/tore/llm/tool.ex`
- Test: `test/tore/llm/tool_test.exs`

### Steps

- [ ] **Step 2.1: Write the failing test**

Create `test/tore/llm/tool_test.exs`:

```elixir
defmodule Tore.LLM.ToolTest do
  use ExUnit.Case, async: true
  alias Tore.LLM.Tool

  test "describes itself as a JSON-serialisable map" do
    t = %Tool{
      name: "skip_meal",
      description: "Mark a slot skipped",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: %{type: "string"}},
        required: ["slot_key"]
      },
      run: fn _args, _ctx -> {:ok, %{ok: true}} end
    }

    assert Tool.to_openai(t) == %{
             type: "function",
             function: %{
               name: "skip_meal",
               description: "Mark a slot skipped",
               parameters: %{
                 type: "object",
                 properties: %{slot_key: %{type: "string"}},
                 required: ["slot_key"]
               }
             }
           }
  end

  test "validates required arguments" do
    t = %Tool{
      name: "skip_meal",
      description: "x",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: %{type: "string"}},
        required: ["slot_key"]
      },
      run: fn _, _ -> {:ok, %{}} end
    }

    assert {:error, {:missing_arg, "slot_key"}} = Tool.validate_args(t, %{})
    assert :ok = Tool.validate_args(t, %{"slot_key" => "mon_dinner"})
  end
end
```

- [ ] **Step 2.2: Run the test to verify it fails**

Run: `mix test test/tore/llm/tool_test.exs`
Expected: FAIL — `Tore.LLM.Tool` not defined.

- [ ] **Step 2.3: Implement the struct**

Create `lib/tore/llm/tool.ex`:

```elixir
defmodule Tore.LLM.Tool do
  @moduledoc """
  A single tool exposed to the LLM. `parameters` is a JSON Schema map. `run`
  receives the decoded args (string-keyed) and a ctx map provided by the
  agent runtime.

      kind: :action — may mutate app state. Counted against the agent's action cap.
      kind: :read   — pure read; not counted against the action cap.
  """

  @enforce_keys [:name, :description, :parameters, :kind, :run]
  defstruct [:name, :description, :parameters, :kind, :run]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          kind: :action | :read,
          run: (map(), map() -> {:ok, term()} | {:error, term()})
        }

  @spec to_openai(t()) :: map()
  def to_openai(%__MODULE__{} = t) do
    %{
      type: "function",
      function: %{
        name: t.name,
        description: t.description,
        parameters: t.parameters
      }
    }
  end

  @spec validate_args(t(), map()) :: :ok | {:error, {:missing_arg, String.t()}}
  def validate_args(%__MODULE__{parameters: %{"required" => req}}, args), do: check_keys(req, args)
  def validate_args(%__MODULE__{parameters: %{required: req}}, args), do: check_keys(req, args)
  def validate_args(_, _), do: :ok

  defp check_keys([], _), do: :ok
  defp check_keys([k | rest], args) when is_binary(k) do
    if Map.has_key?(args, k), do: check_keys(rest, args), else: {:error, {:missing_arg, k}}
  end
  defp check_keys([k | rest], args), do: check_keys([to_string(k) | rest], args)
end
```

- [ ] **Step 2.4: Run the test to verify it passes**

Run: `mix test test/tore/llm/tool_test.exs`
Expected: PASS.

- [ ] **Step 2.5: Commit**

```
jj describe -m "feat(llm): add Tore.LLM.Tool struct for tool-calling agent"
jj new
```

---

## Task 3 — Behaviour callback `chat_with_tools/4`

### Files
- Modify: `lib/tore/llm.ex`

### Why
Behaviour-first: defining the contract before implementations makes the Mox mock work in subsequent tasks.

### Steps

- [ ] **Step 3.1: Add the callback to `Tore.LLM`**

Edit `lib/tore/llm.ex` and append (before the closing `end`):

```elixir
@type tool_call :: %{id: String.t(), name: String.t(), args: map()}
@type tool_response ::
        {:message, String.t()}
        | {:tool_calls, [tool_call()]}

@callback chat_with_tools(
            system :: String.t(),
            messages :: [map()],
            tools :: [map()],
            opts :: keyword()
          ) :: {:ok, tool_response(), usage :: map()} | {:error, term()}
```

The `tools` arg is a list of OpenAI-shaped tool dicts (i.e. the output of `Tool.to_openai/1`). The adapter does not know about `Tore.LLM.Tool` — keeps the boundary clean.

- [ ] **Step 3.2: Run the full test suite to confirm nothing breaks**

Run: `mix test`
Expected: PASS for everything; Mox will require `Tore.MockLLM` to stub `chat_with_tools/4` only in tests that exercise it (those are in Task 6 and 8).

- [ ] **Step 3.3: Commit**

```
jj describe -m "feat(llm): add chat_with_tools/4 callback to Tore.LLM behaviour"
jj new
```

---

## Task 4 — OpenRouter adapter implements `chat_with_tools/4`

### Files
- Modify: `lib/tore/adapters/open_router.ex`
- Test: `test/tore/adapters/open_router_chat_with_tools_test.exs`

### Steps

- [ ] **Step 4.1: Write the failing test**

Create `test/tore/adapters/open_router_chat_with_tools_test.exs`:

```elixir
defmodule Tore.Adapters.OpenRouterChatWithToolsTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!

  alias Tore.Adapters.OpenRouter

  setup do
    Application.put_env(:tore, :http_client, Tore.MockHTTP)
    :ok
  end

  test "returns {:message, text} when the model emits no tool_calls" do
    expect(Tore.MockHTTP, :post, fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "Done.", "tool_calls" => nil}}],
           "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
         }}}
    end)

    assert {:ok, {:message, "Done."}, %{prompt_tokens: 5}} =
             OpenRouter.chat_with_tools("sys", [%{role: "user", content: "hi"}], [], [])
  end

  test "returns {:tool_calls, list} when the model picks tools" do
    expect(Tore.MockHTTP, :post, fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{
                 "content" => nil,
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{
                       "name" => "skip_meal",
                       "arguments" => ~s({"slot_key":"mon_dinner"})
                     }
                   }
                 ]
               }
             }
           ],
           "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
         }}}
    end)

    assert {:ok, {:tool_calls, [call]}, _usage} =
             OpenRouter.chat_with_tools("sys", [%{role: "user", content: "skip mon"}], [
               %{type: "function", function: %{name: "skip_meal", description: "x", parameters: %{}}}
             ], [])

    assert call.id == "call_1"
    assert call.name == "skip_meal"
    assert call.args == %{"slot_key" => "mon_dinner"}
  end
end
```

- [ ] **Step 4.2: Run the test to verify it fails**

Run: `mix test test/tore/adapters/open_router_chat_with_tools_test.exs`
Expected: FAIL — `chat_with_tools/4` not defined.

- [ ] **Step 4.3: Implement `chat_with_tools/4`**

Edit `lib/tore/adapters/open_router.ex`. Add `@behaviour Tore.LLM` is presumably already declared — keep as-is. Append the function (placement: after `chat/2` or in its declared block):

```elixir
@impl Tore.LLM
def chat_with_tools(system, messages, tools, opts) do
  model_name = Keyword.get(opts, :model, model())

  body =
    %{
      model: model_name,
      messages: [%{role: "system", content: system} | messages],
      tools: tools,
      tool_choice: Keyword.get(opts, :tool_choice, "auto")
    }

  http = Application.get_env(:tore, :http_client, Tore.Adapters.ReqHTTP)

  case http.post(@api_url,
         json: body,
         headers: [
           {"Authorization", "Bearer #{api_key()}"},
           {"HTTP-Referer", "https://tore.gustafrydholm.xyz"},
           {"X-Title", "Tore"}
         ]
       ) do
    {:ok, %{status: 200, body: resp}} ->
      msg = get_in(resp, ["choices", Access.at(0), "message"]) || %{}
      usage = extract_usage(resp)

      case msg do
        %{"tool_calls" => calls} when is_list(calls) and calls != [] ->
          {:ok, {:tool_calls, Enum.map(calls, &decode_tool_call/1)}, usage}

        %{"content" => content} when is_binary(content) ->
          {:ok, {:message, content}, usage}

        _ ->
          {:error, {:unexpected_message, msg}}
      end

    {:ok, %{status: 402}} -> {:error, :provider_budget_exceeded}
    {:ok, %{status: 429}} -> {:error, :rate_limited}
    {:ok, %{status: status, body: resp}} -> {:error, {:openrouter_error, status, resp}}
    {:error, reason} -> {:error, {:http_error, reason}}
  end
end

defp decode_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => raw_args}}) do
  args =
    case Jason.decode(raw_args || "{}") do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end

  %{id: id, name: name, args: args}
end
```

If `model()`, `api_key()`, `@api_url`, and `extract_usage/1` are already private helpers in this module, reuse them. If `Tore.Adapters.ReqHTTP` (or the configured `:http_client`) isn't already referenced elsewhere, look at how `json_chat/3` is implemented and mirror that exactly — the goal is to use whatever HTTP indirection the file already uses, not introduce a new one.

> **Note for the implementer:** Inspect the existing `chat/2` and `json_chat/3` in this file. Match their HTTP-client pattern. The test above assumes `Tore.MockHTTP.post/2` is the seam; if the file uses `Req.post/2` directly, switch the seam to `Application.get_env(:tore, :http_client)` first (and add that env wiring to `config/test.exs` if it isn't already there). Do not silently introduce a parallel HTTP path.

- [ ] **Step 4.4: Run the test to verify it passes**

Run: `mix test test/tore/adapters/open_router_chat_with_tools_test.exs`
Expected: PASS.

- [ ] **Step 4.5: Commit**

```
jj describe -m "feat(open_router): implement chat_with_tools/4

Returns {:message, text} or {:tool_calls, [%{id, name, args}]}.
Sends OpenAI-style tools array with tool_choice: auto."
jj new
```

---

## Task 5 — PlannerTools catalog: the six action tools

This task delivers the six tools that mutate planning state. Each wraps an existing `PlanningHandler` function.

### Files
- Create: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_test.exs`

### Steps

- [ ] **Step 5.1: Write failing tests for the action tools**

Create `test/tore/llm/planner_tools_test.exs`:

```elixir
defmodule Tore.LLM.PlannerToolsTest do
  use Tore.DataCase, async: false
  alias Tore.LLM.PlannerTools
  alias Tore.Handlers.PlanningHandler

  @plan_id "plan:test"
  @week_start ~D[2026-06-01]

  setup do
    # Ensure a baseline plan stream exists.
    {:ok, _state} = PlanningHandler.load_plan(@plan_id)
    %{ctx: %{plan_id: @plan_id, week_start: @week_start}}
  end

  test "assign_recipe", %{ctx: ctx} do
    {:ok, %Tore.Recipes.Recipe{id: rid}} =
      Tore.Recipes.create(%{title: "Test Salmon", servings: 2, ingredients: [], instructions: "x"})

    tool = Enum.find(PlannerTools.all(), &(&1.name == "assign_recipe"))
    args = %{"slot_key" => "mon_dinner", "recipe_id" => rid, "servings" => 2}

    assert :ok = Tore.LLM.Tool.validate_args(tool, args)
    assert {:ok, %{ok: true}} = tool.run.(args, ctx)

    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    assert %{recipe_id: ^rid, servings: 2} = state.slots["mon_dinner"]
  end

  test "skip_meal", %{ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "skip_meal"))
    assert {:ok, %{ok: true}} = tool.run.(%{"slot_key" => "tue_dinner"}, ctx)
    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    assert state.slots["tue_dinner"].skipped == true
  end

  test "remove_recipe", %{ctx: ctx} do
    {:ok, %Tore.Recipes.Recipe{id: rid}} =
      Tore.Recipes.create(%{title: "X", servings: 2, ingredients: [], instructions: "x"})

    assign_tool = Enum.find(PlannerTools.all(), &(&1.name == "assign_recipe"))
    remove_tool = Enum.find(PlannerTools.all(), &(&1.name == "remove_recipe"))

    {:ok, _} = assign_tool.run.(%{"slot_key" => "wed_dinner", "recipe_id" => rid, "servings" => 2}, ctx)
    {:ok, _} = remove_tool.run.(%{"slot_key" => "wed_dinner"}, ctx)

    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    refute Map.has_key?(state.slots, "wed_dinner") and not is_nil(state.slots["wed_dinner"].recipe_id)
  end

  test "set_servings", %{ctx: ctx} do
    {:ok, %Tore.Recipes.Recipe{id: rid}} =
      Tore.Recipes.create(%{title: "X", servings: 2, ingredients: [], instructions: "x"})

    assign_tool = Enum.find(PlannerTools.all(), &(&1.name == "assign_recipe"))
    set_tool = Enum.find(PlannerTools.all(), &(&1.name == "set_servings"))

    {:ok, _} = assign_tool.run.(%{"slot_key" => "thu_dinner", "recipe_id" => rid, "servings" => 2}, ctx)
    {:ok, _} = set_tool.run.(%{"slot_key" => "thu_dinner", "servings" => 4}, ctx)

    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    assert state.slots["thu_dinner"].servings == 4
  end

  test "mark_leftover", %{ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "mark_leftover"))
    assert {:ok, %{ok: true}} = tool.run.(%{"slot_key" => "fri_dinner"}, ctx)
    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    assert state.slots["fri_dinner"].leftover == true
  end

  test "swap_recipe moves a recipe between two slots", %{ctx: ctx} do
    {:ok, %Tore.Recipes.Recipe{id: rid}} =
      Tore.Recipes.create(%{title: "Salmon", servings: 2, ingredients: [], instructions: "x"})

    assign_tool = Enum.find(PlannerTools.all(), &(&1.name == "assign_recipe"))
    swap_tool = Enum.find(PlannerTools.all(), &(&1.name == "swap_recipe"))

    {:ok, _} = assign_tool.run.(%{"slot_key" => "tue_dinner", "recipe_id" => rid, "servings" => 2}, ctx)
    {:ok, _} = swap_tool.run.(%{"from_slot_key" => "tue_dinner", "to_slot_key" => "fri_dinner"}, ctx)

    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    assert state.slots["fri_dinner"].recipe_id == rid
    assert is_nil(state.slots["tue_dinner"][:recipe_id]) or state.slots["tue_dinner"].recipe_id == nil
  end

  test "ask_user returns a terminal result", %{ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "ask_user"))
    assert {:ok, %{ask_user: "Which salmon?"}} = tool.run.(%{"question" => "Which salmon?"}, ctx)
  end
end
```

- [ ] **Step 5.2: Run the test to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — `Tore.LLM.PlannerTools` not defined.

- [ ] **Step 5.3: Implement the catalog (action tools first)**

Create `lib/tore/llm/planner_tools.ex`:

```elixir
defmodule Tore.LLM.PlannerTools do
  @moduledoc """
  Tool catalog for the planner agent. Each tool's `run` function takes
  string-keyed args from the LLM and a `ctx` map (must include :plan_id
  and :week_start). Action tools call PlanningHandler; read tools call
  Recipes/Pantry/Deals. `ask_user` is a terminal signal — the agent
  runtime recognises it and stops the loop.
  """

  alias Tore.LLM.Tool
  alias Tore.Handlers.PlanningHandler

  @slot_key %{type: "string", description: "Slot identifier like \"mon_dinner\""}

  @spec all() :: [Tool.t()]
  def all do
    [
      assign_recipe(),
      swap_recipe(),
      skip_meal(),
      mark_leftover(),
      set_servings(),
      remove_recipe(),
      ask_user(),
      # read tools added in Task 6
      search_recipes(),
      pantry_snapshot(),
      active_deals()
    ]
  end

  # ---------- Action tools ----------

  defp assign_recipe do
    %Tool{
      name: "assign_recipe",
      description: "Place a recipe in a slot. Sets servings.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{
          slot_key: @slot_key,
          recipe_id: %{type: "integer"},
          servings: %{type: "integer", minimum: 1}
        },
        required: ["slot_key", "recipe_id", "servings"]
      },
      run: fn args, ctx ->
        PlanningHandler.assign_recipe(
          ctx.plan_id,
          args["slot_key"],
          args["recipe_id"],
          args["servings"]
        )
        |> wrap_ok()
      end
    }
  end

  defp swap_recipe do
    %Tool{
      name: "swap_recipe",
      description: "Move whatever is in from_slot_key into to_slot_key. The source slot is cleared.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{
          from_slot_key: @slot_key,
          to_slot_key: @slot_key
        },
        required: ["from_slot_key", "to_slot_key"]
      },
      run: fn args, ctx ->
        with {:ok, state} <- PlanningHandler.load_plan(ctx.plan_id),
             slot when not is_nil(slot) <- Map.get(state.slots, args["from_slot_key"]),
             rid when not is_nil(rid) <- Map.get(slot, :recipe_id),
             servings <- Map.get(slot, :servings) || 2,
             {:ok, _} <- PlanningHandler.assign_recipe(ctx.plan_id, args["to_slot_key"], rid, servings),
             {:ok, _} <- PlanningHandler.remove_recipe(ctx.plan_id, args["from_slot_key"]) do
          {:ok, %{ok: true}}
        else
          nil -> {:error, :nothing_to_swap}
          {:error, reason} -> {:error, reason}
        end
      end
    }
  end

  defp skip_meal do
    %Tool{
      name: "skip_meal",
      description: "Mark a slot as skipped. Neutral; no warning, no cascade.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key},
        required: ["slot_key"]
      },
      run: fn args, ctx ->
        PlanningHandler.skip_meal(ctx.plan_id, args["slot_key"]) |> wrap_ok()
      end
    }
  end

  defp mark_leftover do
    %Tool{
      name: "mark_leftover",
      description: "Mark a slot as leftovers from a prior meal.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key},
        required: ["slot_key"]
      },
      run: fn args, ctx ->
        PlanningHandler.mark_leftover(ctx.plan_id, args["slot_key"]) |> wrap_ok()
      end
    }
  end

  defp set_servings do
    %Tool{
      name: "set_servings",
      description: "Change servings for a slot's recipe.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key, servings: %{type: "integer", minimum: 1}},
        required: ["slot_key", "servings"]
      },
      run: fn args, ctx ->
        PlanningHandler.set_servings(ctx.plan_id, args["slot_key"], args["servings"]) |> wrap_ok()
      end
    }
  end

  defp remove_recipe do
    %Tool{
      name: "remove_recipe",
      description: "Clear a slot.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key},
        required: ["slot_key"]
      },
      run: fn args, ctx ->
        PlanningHandler.remove_recipe(ctx.plan_id, args["slot_key"]) |> wrap_ok()
      end
    }
  end

  defp ask_user do
    %Tool{
      name: "ask_user",
      description:
        "Surface a clarifying question to the user instead of guessing. Terminal: the agent stops the loop and shows the question.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{question: %{type: "string"}},
        required: ["question"]
      },
      run: fn args, _ctx -> {:ok, %{ask_user: args["question"]}} end
    }
  end

  # Stubs — implemented in Task 6. Returning a clear error makes Task 5's
  # tests fail fast if a read tool is invoked before it's been built.
  defp search_recipes,
    do: %Tool{
      name: "search_recipes",
      description: "stub",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _, _ -> {:error, :not_implemented} end
    }

  defp pantry_snapshot,
    do: %Tool{
      name: "pantry_snapshot",
      description: "stub",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _, _ -> {:error, :not_implemented} end
    }

  defp active_deals,
    do: %Tool{
      name: "active_deals",
      description: "stub",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _, _ -> {:error, :not_implemented} end
    }

  defp wrap_ok({:ok, _}), do: {:ok, %{ok: true}}
  defp wrap_ok({:error, reason}), do: {:error, reason}
end
```

- [ ] **Step 5.4: Run the test to verify the action tools pass**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: PASS for all 7 cases (including `ask_user`). Read-tool stubs are exercised separately in Task 6.

- [ ] **Step 5.5: Commit**

```
jj describe -m "feat(llm): PlannerTools — 6 action tools + ask_user

Each action tool wraps an existing PlanningHandler call. ask_user is
terminal; the agent runtime stops the loop when it fires. Read tools
(search_recipes, pantry_snapshot, active_deals) are stubbed and built
in the next task."
jj new
```

---

## Task 6 — PlannerTools: the three read tools

### Files
- Modify: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_test.exs` (extend)

### Steps

- [ ] **Step 6.1: Write failing tests for read tools**

Append to `test/tore/llm/planner_tools_test.exs`:

```elixir
describe "read tools" do
  setup do
    {:ok, r1} = Tore.Recipes.create(%{title: "Quick Pasta", servings: 2, ingredients: [], instructions: "x", total_minutes: 20})
    {:ok, r2} = Tore.Recipes.create(%{title: "Slow Stew",  servings: 4, ingredients: [], instructions: "x", total_minutes: 180})
    %{r1: r1, r2: r2, ctx: %{plan_id: "plan:test", week_start: ~D[2026-06-01]}}
  end

  test "search_recipes returns matches", %{r1: r1, ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "search_recipes"))
    assert {:ok, %{recipes: results}} = tool.run.(%{"query" => "pasta"}, ctx)
    assert Enum.any?(results, fn r -> r.id == r1.id end)
  end

  test "search_recipes respects max_minutes", %{r1: r1, r2: r2, ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "search_recipes"))
    assert {:ok, %{recipes: results}} = tool.run.(%{"max_minutes" => 30}, ctx)
    ids = Enum.map(results, & &1.id)
    assert r1.id in ids
    refute r2.id in ids
  end

  test "pantry_snapshot returns the current inventory", %{ctx: ctx} do
    {:ok, _} = Tore.Pantry.add_item(%{name: "olive oil", quantity: Decimal.new(1), unit: "bottle"})
    tool = Enum.find(PlannerTools.all(), &(&1.name == "pantry_snapshot"))
    assert {:ok, %{items: items}} = tool.run.(%{}, ctx)
    assert Enum.any?(items, &(&1.name == "olive oil"))
  end

  test "active_deals returns current deals list", %{ctx: ctx} do
    tool = Enum.find(PlannerTools.all(), &(&1.name == "active_deals"))
    assert {:ok, %{deals: deals}} = tool.run.(%{}, ctx)
    assert is_list(deals)
  end
end
```

- [ ] **Step 6.2: Run the test to verify it fails**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: FAIL — read tools return `{:error, :not_implemented}`.

- [ ] **Step 6.3: Replace the stubs in `lib/tore/llm/planner_tools.ex`**

Replace the three stub functions:

```elixir
defp search_recipes do
  %Tool{
    name: "search_recipes",
    description:
      "Search the recipe catalog. Combine query text, max cooking time, and a limit. Use this before assigning so you pick a real recipe_id.",
    kind: :read,
    parameters: %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Free-text search across titles and ingredients"},
        max_minutes: %{type: "integer", minimum: 1},
        limit: %{type: "integer", minimum: 1, maximum: 25}
      },
      required: []
    },
    run: fn args, _ctx ->
      limit = Map.get(args, "limit", 8)
      base =
        case args["query"] do
          q when is_binary(q) and byte_size(q) > 0 -> Tore.Recipes.search(q)
          _ -> Tore.Recipes.list(limit: limit)
        end

      filtered =
        case args["max_minutes"] do
          n when is_integer(n) -> Enum.filter(base, &recipe_under_minutes?(&1, n))
          _ -> base
        end

      result =
        filtered
        |> Enum.take(limit)
        |> Enum.map(&summarise_recipe/1)

      {:ok, %{recipes: result}}
    end
  }
end

defp pantry_snapshot do
  %Tool{
    name: "pantry_snapshot",
    description:
      "Approximate pantry inventory. Treat results as inexact — items may be missing or stale. Use before suggesting recipes that depend on specific ingredients.",
    kind: :read,
    parameters: %{type: "object", properties: %{}, required: []},
    run: fn _args, _ctx ->
      items =
        Tore.Pantry.list_inventory()
        |> Enum.map(fn it ->
          %{
            id: it.id,
            name: it.name,
            quantity: it.quantity && Decimal.to_string(it.quantity),
            unit: it.unit,
            category: it.category
          }
        end)

      {:ok, %{items: items}}
    end
  }
end

defp active_deals do
  %Tool{
    name: "active_deals",
    description: "Currently active store deals across configured stores.",
    kind: :read,
    parameters: %{type: "object", properties: %{}, required: []},
    run: fn _args, _ctx ->
      deals =
        Tore.Deals.list_current()
        |> Enum.map(fn d ->
          %{id: d.id, name: d.name, price: d.price && Decimal.to_string(d.price), store: d.store_name}
        end)

      {:ok, %{deals: deals}}
    end
  }
end

defp recipe_under_minutes?(%{total_minutes: m}, max) when is_integer(m), do: m <= max
defp recipe_under_minutes?(_, _), do: false

defp summarise_recipe(r) do
  %{
    id: r.id,
    title: r.title,
    servings: r.servings,
    total_minutes: Map.get(r, :total_minutes)
  }
end
```

> **Note for the implementer:** The exact field names depend on the `Tore.Recipes.Recipe` schema. Open it (`lib/tore/recipes/recipe.ex`) and confirm `total_minutes`, `servings`, `title`. If a field has a different name (e.g. `cook_minutes`), use that name in both the schema check and the summary map. Do not invent fields.

- [ ] **Step 6.4: Run the test to verify it passes**

Run: `mix test test/tore/llm/planner_tools_test.exs`
Expected: all read-tool tests PASS.

- [ ] **Step 6.5: Commit**

```
jj describe -m "feat(llm): wire PlannerTools read tools to Recipes, Pantry, Deals

search_recipes supports query + max_minutes + limit; pantry_snapshot and
active_deals return summarised maps suitable for an LLM context window."
jj new
```

---

## Task 7 — PlannerAgent loop runtime

### Files
- Create: `lib/tore/llm/planner_agent.ex`
- Test: `test/tore/llm/planner_agent_test.exs`

### Steps

- [ ] **Step 7.1: Write failing tests**

Create `test/tore/llm/planner_agent_test.exs`:

```elixir
defmodule Tore.LLM.PlannerAgentTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.LLM.PlannerAgent

  @plan_id "plan:test"

  setup do
    {:ok, _} = Tore.Handlers.PlanningHandler.load_plan(@plan_id)
    %{ctx: %{plan_id: @plan_id, week_start: ~D[2026-06-01]}}
  end

  test "single round-trip ending in a message", %{ctx: ctx} do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Nothing to change."}, %{prompt_tokens: 5, completion_tokens: 2}}
    end)

    assert {:ok, %{final_message: "Nothing to change.", actions: [], correlation_id: cid}} =
             PlannerAgent.run("look at next week", ctx)

    assert is_binary(cid)
    [row] = Tore.AiOperations.list_by_correlation(cid)
    assert row.step_index == 0
  end

  test "executes a single action and ends", %{ctx: ctx} do
    me = self()

    expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
      send(me, {:msg_count, length(msgs)})

      {:ok,
       {:tool_calls,
        [%{id: "c1", name: "skip_meal", args: %{"slot_key" => "mon_dinner"}}]},
       %{prompt_tokens: 8, completion_tokens: 4}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Skipped Monday."}, %{prompt_tokens: 12, completion_tokens: 3}}
    end)

    assert {:ok, %{final_message: "Skipped Monday.", actions: actions}} =
             PlannerAgent.run("skip mon dinner", ctx)

    assert [%{name: "skip_meal", ok: true}] = actions
    assert_received {:msg_count, 1}

    {:ok, state} = Tore.Handlers.PlanningHandler.load_plan(@plan_id)
    assert state.slots["mon_dinner"].skipped == true
  end

  test "ask_user is terminal", %{ctx: ctx} do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls, [%{id: "c1", name: "ask_user", args: %{"question" => "Which salmon?"}}]},
       %{}}
    end)

    assert {:ok, %{question: "Which salmon?", actions: []}} =
             PlannerAgent.run("move the salmon", ctx)
  end

  test "round-trip cap forces a final summary", %{ctx: ctx} do
    # Always reply with a tool call; the agent must stop after the cap.
    stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, tools, _opts ->
      # On the final forced call, `tools` is [] — at that point return a message.
      case tools do
        [] -> {:ok, {:message, "Stopped after cap."}, %{}}
        _ ->
          {:ok,
           {:tool_calls,
            [%{id: "loop", name: "skip_meal", args: %{"slot_key" => "wed_dinner"}}]},
           %{}}
      end
    end)

    assert {:ok, %{final_message: "Stopped after cap.", capped: true}} =
             PlannerAgent.run("loop", ctx, max_round_trips: 2)
  end

  test "tool error is fed back to the model", %{ctx: ctx} do
    expect(Tore.MockLLM, :chat_with_tools, 2, fn _sys, msgs, _tools, _opts ->
      tool_role_present = Enum.any?(msgs, &(&1[:role] == "tool" or &1["role"] == "tool"))

      if tool_role_present do
        {:ok, {:message, "Retrying."}, %{}}
      else
        {:ok,
         {:tool_calls,
          [%{id: "c1", name: "assign_recipe",
             args: %{"slot_key" => "mon_dinner", "recipe_id" => 999_999, "servings" => 2}}]},
         %{}}
      end
    end)

    assert {:ok, %{final_message: "Retrying.", actions: [%{ok: false, error: _}]}} =
             PlannerAgent.run("assign bogus", ctx)
  end
end
```

- [ ] **Step 7.2: Run the tests to verify they fail**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: FAIL — `Tore.LLM.PlannerAgent` not defined.

- [ ] **Step 7.3: Implement `PlannerAgent`**

Create `lib/tore/llm/planner_agent.ex`:

```elixir
defmodule Tore.LLM.PlannerAgent do
  @moduledoc """
  Bounded tool-calling loop for the planner command bar. See SPEC.md §2.

  Returns one of:

      {:ok, %{
        final_message: String.t() | nil,
        question:      String.t() | nil,
        actions:       [%{name: String.t(), ok: boolean(), error: term() | nil}],
        capped:        boolean(),
        correlation_id: String.t()
      }}
      {:error, term()}
  """

  alias Tore.LLM.{Tool, PlannerTools}

  @llm Application.compile_env(:tore, :llm_client)

  @default_max_round_trips 6
  @default_max_action_calls 12

  @spec run(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(user_text, ctx, opts \\ []) do
    max_round_trips = Keyword.get(opts, :max_round_trips, @default_max_round_trips)
    max_action_calls = Keyword.get(opts, :max_action_calls, @default_max_action_calls)
    correlation_id = Keyword.get(opts, :correlation_id, generate_cid())

    tools = PlannerTools.all()
    tools_json = Enum.map(tools, &Tool.to_openai/1)
    system_prompt = Tore.Chat.SystemPrompt.build()

    state = %{
      ctx: Map.put(ctx, :correlation_id, correlation_id),
      tools_by_name: Map.new(tools, &{&1.name, &1}),
      tools_json: tools_json,
      messages: [%{role: "user", content: user_text}],
      actions: [],
      step_index: 0,
      action_calls: 0,
      round_trips: 0,
      max_round_trips: max_round_trips,
      max_action_calls: max_action_calls,
      correlation_id: correlation_id,
      capped: false,
      question: nil
    }

    loop(system_prompt, state)
  end

  # ---------- Loop ----------

  defp loop(system, %{round_trips: rt, max_round_trips: max} = state) when rt >= max do
    # Force final summary turn with no tools available.
    case @llm.chat_with_tools(system, state.messages, [], []) do
      {:ok, {:message, text}, usage} ->
        log(state, usage, "capped_final", text)
        finish(%{state | capped: true}, text)

      {:ok, _other, usage} ->
        log(state, usage, "capped_unknown", "")
        finish(%{state | capped: true}, "Stopped — too many steps.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(system, state) do
    case @llm.chat_with_tools(system, state.messages, state.tools_json, []) do
      {:ok, {:message, text}, usage} ->
        log(state, usage, "message", text)
        finish(state, text)

      {:ok, {:tool_calls, calls}, usage} ->
        log(state, usage, "tool_calls", encode_calls(calls))
        state = %{state | step_index: state.step_index + 1, round_trips: state.round_trips + 1}

        case execute_calls(calls, state) do
          {:terminal_question, question, state} ->
            {:ok,
             %{
               final_message: nil,
               question: question,
               actions: Enum.reverse(state.actions),
               capped: false,
               correlation_id: state.correlation_id
             }}

          {:cap_hit, state} ->
            loop(system, %{state | round_trips: state.max_round_trips})

          {:continue, state} ->
            loop(system, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_calls([], state), do: {:continue, state}

  defp execute_calls([call | rest], state) do
    case Map.fetch(state.tools_by_name, call.name) do
      :error ->
        state = append_tool_result(state, call, %{error: "unknown_tool"})
        execute_calls(rest, state)

      {:ok, tool} ->
        handle_tool(tool, call, rest, state)
    end
  end

  defp handle_tool(%Tool{name: "ask_user"} = tool, call, _rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        {:ok, %{ask_user: question}} = tool.run.(call.args, state.ctx)
        state = append_tool_result(state, call, %{ok: true, question: question})
        {:terminal_question, question, state}

      {:error, _} = err ->
        state = append_tool_result(state, call, %{error: inspect(err)})
        {:continue, state}
    end
  end

  defp handle_tool(%Tool{kind: :action} = tool, call, rest, state) do
    if state.action_calls >= state.max_action_calls do
      state = append_tool_result(state, call, %{error: "action_cap_reached"})
      {:cap_hit, %{state | actions: [%{name: call.name, ok: false, error: :cap} | state.actions]}}
    else
      run_and_record(tool, call, rest, %{state | action_calls: state.action_calls + 1})
    end
  end

  defp handle_tool(%Tool{kind: :read} = tool, call, rest, state) do
    run_and_record(tool, call, rest, state)
  end

  defp run_and_record(tool, call, rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        case tool.run.(call.args, state.ctx) do
          {:ok, result} ->
            state = append_tool_result(state, call, result)
            state =
              if tool.kind == :action,
                do: %{state | actions: [%{name: call.name, ok: true, error: nil} | state.actions]},
                else: state

            execute_calls(rest, state)

          {:error, reason} ->
            state = append_tool_result(state, call, %{error: inspect(reason)})
            state =
              if tool.kind == :action,
                do: %{state | actions: [%{name: call.name, ok: false, error: reason} | state.actions]},
                else: state

            execute_calls(rest, state)
        end

      {:error, reason} ->
        state = append_tool_result(state, call, %{error: inspect(reason)})
        execute_calls(rest, state)
    end
  end

  defp append_tool_result(state, call, result) do
    msg = %{
      role: "tool",
      tool_call_id: call.id,
      name: call.name,
      content: Jason.encode!(result)
    }

    %{state | messages: state.messages ++ [assistant_tool_call(call), msg]}
  end

  # The OpenAI tool-call protocol expects the assistant turn that *emitted*
  # the tool call to appear before the tool result in the message history.
  # We synthesise a minimal stand-in here.
  defp assistant_tool_call(call) do
    %{
      role: "assistant",
      content: nil,
      tool_calls: [
        %{
          id: call.id,
          type: "function",
          function: %{name: call.name, arguments: Jason.encode!(call.args)}
        }
      ]
    }
  end

  defp finish(state, final_message) do
    {:ok,
     %{
       final_message: final_message,
       question: nil,
       actions: Enum.reverse(state.actions),
       capped: state.capped,
       correlation_id: state.correlation_id
     }}
  end

  defp log(state, usage, kind, result) do
    Tore.AiOperations.log(%{
      correlation_id: state.correlation_id,
      kind: "planner_agent." <> kind,
      step_index: state.step_index,
      payload: Jason.encode!(%{messages_count: length(state.messages), usage: usage}),
      result: truncate(result, 4_000)
    })

    :ok
  end

  defp encode_calls(calls), do: Jason.encode!(calls)

  defp truncate(s, max) when is_binary(s) and byte_size(s) > max,
    do: binary_part(s, 0, max) <> "…"
  defp truncate(s, _), do: s

  defp generate_cid do
    "pa-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
```

- [ ] **Step 7.4: Run the tests to verify they pass**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: PASS for all four cases (single-message, single-action, ask_user terminal, round-trip cap, tool-error feedback).

If the "tool error fed back" test still fails because `Mox.expect` with `2` doesn't match the actual call count, check whether the LLM stub is being invoked with the additional tool-result message; loosen to `stub` if needed. The intent is: after a failed action, the agent loops again and reaches a final message.

- [ ] **Step 7.5: Commit**

```
jj describe -m "feat(llm): PlannerAgent — bounded tool-calling loop

- max 6 round-trips, 12 action calls per utterance (configurable)
- ask_user is terminal
- tool errors are fed back as tool-role messages
- every iteration logs to ai_operations with shared correlation_id
- action results are aggregated and returned to the caller"
jj new
```

---

## Task 8 — Wire PlannerLive command bar to PlannerAgent

### Files
- Modify: `lib/tore_web/live/planner_live.ex`
- Test: `test/tore_web/live/planner_live_test.exs` (extend; create if missing)

### Steps

- [ ] **Step 8.1: Write the failing LiveView test**

Append to (or create) `test/tore_web/live/planner_live_test.exs`:

```elixir
defmodule ToreWeb.PlannerLiveAgentTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  setup :verify_on_exit!
  setup :log_in_member_user # whatever helper exists for an authed conn

  test "quick command routes through PlannerAgent and renders results", %{conn: conn} do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Done — skipped Monday dinner."}, %{}}
    end)

    {:ok, view, _} = live(conn, "/plan")

    rendered =
      view
      |> form("form[phx-submit=quick_command]", %{command: "skip mon dinner"})
      |> render_submit()

    assert rendered =~ "Done — skipped Monday dinner."
  end

  test "ask_user surfaces the question inline", %{conn: conn} do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [%{id: "c1", name: "ask_user", args: %{"question" => "Which salmon recipe?"}}]},
       %{}}
    end)

    {:ok, view, _} = live(conn, "/plan")

    rendered =
      view
      |> form("form[phx-submit=quick_command]", %{command: "move the salmon"})
      |> render_submit()

    assert rendered =~ "Which salmon recipe?"
  end
end
```

If `log_in_member_user` doesn't exist in your conn case helpers, replace with whatever the existing planner_live_test uses to authenticate. **Do not invent a helper** — open `test/tore_web/live/planner_live_test.exs` and copy its setup.

- [ ] **Step 8.2: Run the test to verify it fails**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: FAIL — the current `quick_command` handler calls `ChatHandler.handle_text`, which calls `Tore.MockLLM.chat/2`, not `chat_with_tools/4`.

- [ ] **Step 8.3: Replace the `quick_command` handler**

In `lib/tore_web/live/planner_live.ex`:

1. Find the existing `handle_event("quick_command", ...)` clauses (around lines 203-216) and the `handle_info({:run_quick_command, command}, socket)` (around line 279-287). Replace the `handle_info` body:

```elixir
def handle_info({:run_quick_command, command}, socket) do
  ctx = %{
    plan_id: socket.assigns.plan_id,
    week_start: socket.assigns.week_start
  }

  result =
    case Tore.LLM.PlannerAgent.run(command, ctx) do
      {:ok, %{question: q}} when is_binary(q) ->
        %{kind: :question, text: q}

      {:ok, %{final_message: msg, actions: actions, capped: capped}} ->
        %{kind: :message, text: msg, actions: actions, capped: capped}

      {:error, reason} ->
        %{kind: :error, text: format_agent_error(reason)}
    end

  {:noreply, assign(socket, quick_reply: result, quick_loading: false)}
end

defp format_agent_error(:provider_budget_exceeded), do: gettext("Monthly LLM budget reached")
defp format_agent_error(:rate_limited), do: gettext("Please wait a moment before trying again")
defp format_agent_error(_), do: gettext("Something went wrong. Try again.")
```

2. The `:quick_reply` assign is now a structured map, not a bare string. Update the template around line 378 (the `quick_command` form) to render based on `:kind`. Find the existing rendering of `@quick_reply` and replace with:

```heex
<%= case @quick_reply do %>
  <% nil -> %>
    <%# no reply yet %>
  <% %{kind: :message, text: text, actions: actions, capped: capped} -> %>
    <div class="rounded-lg border border-stone-200 bg-white p-3">
      <p class="text-stone-900"><%= text %></p>
      <%= if actions != [] do %>
        <p class="mt-2 text-xs text-stone-500">
          <%= length(actions) %> change<%= if length(actions) == 1, do: "", else: "s" %> applied
          <%= if capped, do: " (stopped after step limit)" %>
        </p>
      <% end %>
      <button type="button" phx-click="dismiss_quick_reply" class="mt-2 text-sm text-stone-500 underline">
        <%= gettext("Dismiss") %>
      </button>
    </div>
  <% %{kind: :question, text: q} -> %>
    <div class="rounded-lg border border-amber-300 bg-amber-50 p-3">
      <p class="text-stone-900"><%= q %></p>
      <button type="button" phx-click="dismiss_quick_reply" class="mt-2 text-sm text-stone-500 underline">
        <%= gettext("Dismiss") %>
      </button>
    </div>
  <% %{kind: :error, text: text} -> %>
    <div class="rounded-lg border border-red-300 bg-red-50 p-3 text-red-900"><%= text %></div>
<% end %>
```

> **Note for the implementer:** the existing template may render `@quick_reply` as a bare string in multiple places. Search for every reference (`grep -n "quick_reply" lib/tore_web/live/planner_live.ex`) and update each. The `nil` and string-case template branches will crash with the new structured map.

3. Remove the now-unused `Tore.Chat.SystemPrompt.build()` + `Tore.Chat.ChatHandler.handle_text/2` call from the old `handle_info` body. The agent assembles its own system prompt internally.

- [ ] **Step 8.4: Run the LiveView tests to verify they pass**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS for both new cases. Existing tests still pass.

- [ ] **Step 8.5: Run the full suite**

Run: `mix test`
Expected: PASS. If any other test stubbed `Tore.MockLLM.chat/2` for the planner path, update it to stub `chat_with_tools/4`.

- [ ] **Step 8.6: Commit**

```
jj describe -m "feat(planner): route command bar through PlannerAgent

quick_command now opens a bounded tool-calling loop that can execute
planner actions, look up recipes/pantry/deals, or ask the user a
clarifying question. The reply box renders distinct UIs for message,
question, and error outcomes."
jj new
```

---

## Task 9 — Manual smoke test against OpenRouter

### Goal
Confirm the loop works against a real model before declaring §2 done.

### Steps

- [ ] **Step 9.1: Confirm `config/dev.exs` uses the OpenRouter adapter**

Run: `grep llm_client config/dev.exs`
Expected: `config :tore, :llm_client, Tore.Adapters.OpenRouter` (no override).

- [ ] **Step 9.2: Start the server**

Run: `mix phx.server`
Open `/plan` in a browser, log in as a real user.

- [ ] **Step 9.3: Execute three smoke utterances and verify**

For each, type into the command bar and observe both the UI and the DB:

| Utterance | Expected UI | Expected DB |
|-----------|-------------|-------------|
| "Skip Monday dinner" | Confirmation: 1 change applied | `planning` event stream has `MealSkipped{slot_key: "mon_dinner"}` |
| "What's a quick chicken recipe for Tuesday?" | A recipe is assigned OR an `ask_user` question is shown | If assigned: `RecipeAssigned` event |
| "Move the salmon to Friday" | Either swap completes, or `ask_user` asks which salmon | Two events if swap completed |

Check `ai_operations` via `iex -S mix`:

```elixir
Tore.AiOperations.list_by_correlation("<cid_from_logs>")
```

Expected: ≥2 rows for the chicken utterance (model rounds: tool_calls → message), all with the same `correlation_id` and ascending `step_index`.

- [ ] **Step 9.4: If anything is off, file follow-up commits — do not paper over with prompt tuning at the agent level**

The point of bounded tool-calling is that real failures are debuggable. If the model picks the wrong tool, that's a *system prompt* fix (in `Tore.Chat.SystemPrompt`). If actions execute against the wrong slot_key, that's a *tool description* fix.

- [ ] **Step 9.5: Commit any follow-up tuning separately**

```
jj describe -m "chore(planner_agent): tune <something> after smoke run"
jj new
```

---

## Done When

1. `mix test` is green.
2. `/plan`'s command bar:
   - Executes "skip mon dinner" without asking.
   - Returns a clarifying question for genuinely ambiguous input.
   - Renders a structured reply (not a bare LLM string) including action count.
3. `ai_operations` shows one `correlation_id` per utterance, with one row per loop iteration ordered by `step_index`.
4. No call path remains where the planner command bar goes through `ChatHandler.handle_text/2`.
5. Spec success criterion #5 ("PlannerAgent runs a bounded tool-calling loop driven from the planner command bar, with all action tools wired through PlanningHandler and at least two read tools wired to real context state") is satisfied — confirmed by the smoke run.

---

## Self-Review Notes

- Spec coverage check: Tasks 1-9 cover SPEC §2 in full, plus the §"LLM Interface Conventions" Pattern B contract (Task 3). They do not touch other LLM-native features (#1 longitudinal learning, #3 ambient scan, #4 inferred pantry, #5 receipt→pantry, #6 fridge→suggestions). Those have their own future PLAN_FEAT docs.
- Placeholder scan: no TBD/TODO/"add appropriate error handling" — every step has runnable code.
- Type consistency: `PlannerTools.all/0` returns `[Tool.t()]`; `PlannerAgent` indexes by `name`; tests reference `:plan_id` and `:week_start` consistently in `ctx`.
- Risks flagged inline (with "Note for the implementer"): unknown `Recipe` field names, existing template branches on `@quick_reply` that may crash with structured map, existing HTTP-client seam in `OpenRouter` that may need a pre-task tidy.
