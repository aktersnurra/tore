# Phase 4 — Chat Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the AI chat assistant — FAB opens full-screen chat, ChatHandler routes natural-language input to the LLM and returns a reply, `ai_operations` logs every AI mutation for future undo.

**Architecture:** `Tore.Chat.SystemPrompt.build/0` assembles per-session context. `Tore.Chat.ChatHandler.handle_text/2` makes a single LLM call and returns `{:ok, reply, nil}` (action dispatch is a Phase 4 extension). `ChatLive` renders the conversation at `/chat`. `ai_operations` table logs every call.

**Tech Stack:** Elixir/Phoenix/LiveView, Mox (`Tore.MockLLM`) for LLM mock, SQLite/Ecto, `jj describe -m` for commits.

**LLM wiring convention (existing pattern):**
- Config key: `config :tore, :llm_client, <module>` (prod = `Tore.Adapters.OpenRouter`, test = `Tore.MockLLM`)
- Handlers reference it via `@llm Application.compile_env(:tore, :llm_client)`
- Mox mock: `Tore.MockLLM` defined in `test/support/mocks.ex`

---

## Task 1 — `ai_operations` migration + schema + context

### Files
- `priv/repo/migrations/20260529000010_create_ai_operations.exs`
- `lib/tore/ai_operations/ai_operation.ex`
- `lib/tore/ai_operations.ex`
- `test/tore/ai_operations_test.exs`

### Migration

```elixir
defmodule Tore.Repo.Migrations.CreateAiOperations do
  use Ecto.Migration

  def change do
    create table(:ai_operations) do
      add :correlation_id, :string, null: false
      add :kind, :string, null: false
      add :payload, :text
      add :result, :text
      add :undo_op_id, :integer
      add :inserted_at, :utc_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create unique_index(:ai_operations, [:correlation_id])
  end
end
```

### Schema

```elixir
# lib/tore/ai_operations/ai_operation.ex
defmodule Tore.AiOperations.AiOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_operations" do
    field :correlation_id, :string
    field :kind, :string
    field :payload, :string
    field :result, :string
    field :undo_op_id, :integer
    field :inserted_at, :utc_datetime, autogenerate: false
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:correlation_id, :kind, :payload, :result, :undo_op_id])
    |> validate_required([:correlation_id, :kind])
    |> unique_constraint(:correlation_id)
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

### Context

```elixir
# lib/tore/ai_operations.ex
defmodule Tore.AiOperations do
  alias Tore.{Repo, AiOperations.AiOperation}
  import Ecto.Query

  @spec log(map()) :: {:ok, AiOperation.t()} | {:error, Ecto.Changeset.t()}
  def log(attrs) do
    %AiOperation{}
    |> AiOperation.changeset(attrs)
    |> Repo.insert()
  end

  @spec find_by_correlation(String.t()) :: AiOperation.t() | nil
  def find_by_correlation(correlation_id) do
    Repo.one(from o in AiOperation, where: o.correlation_id == ^correlation_id)
  end
end
```

### Tests

```elixir
# test/tore/ai_operations_test.exs
defmodule Tore.AiOperationsTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "log/1 and find_by_correlation/1 round-trip" do
    correlation_id = "test-#{System.unique_integer()}"

    assert {:ok, op} =
             Tore.AiOperations.log(%{
               correlation_id: correlation_id,
               kind: "chat",
               payload: "What's for dinner?",
               result: "Pasta"
             })

    assert op.kind == "chat"
    found = Tore.AiOperations.find_by_correlation(correlation_id)
    assert found.id == op.id
    assert found.result == "Pasta"
  end

  test "log/1 returns error on duplicate correlation_id" do
    correlation_id = "dup-#{System.unique_integer()}"
    assert {:ok, _} = Tore.AiOperations.log(%{correlation_id: correlation_id, kind: "chat"})
    assert {:error, changeset} = Tore.AiOperations.log(%{correlation_id: correlation_id, kind: "chat"})
    assert {:correlation_id, _} = hd(changeset.errors)
  end
end
```

### Commit
```
jj describe -m "feat: ai_operations table, schema, and context with log/find_by_correlation"
```

---

## Task 2 — Add `chat/2` callback to `Tore.LLM` + implement in `Tore.Adapters.OpenRouter`

### Files
- `lib/tore/llm.ex` — add one `@callback`
- `lib/tore/adapters/open_router.ex` — add one `@impl` function
- `test/tore/adapters/open_router_chat_test.exs`

### `lib/tore/llm.ex` change

Add after line 31 (after `cook_mode_steps` callback):

```elixir
  @callback chat(system :: String.t(), messages :: [map()]) ::
              {:ok, String.t(), map()} | {:error, term()}
```

### `lib/tore/adapters/open_router.ex` addition

Add a new `@impl Tore.LLM` function. The existing private `chat/3` uses JSON response format; the new public `chat/2` sends free-text messages and returns the raw string content (no JSON parsing):

```elixir
@impl Tore.LLM
def chat(system, messages) do
  body = %{
    model: model(),
    messages: [%{role: "system", content: system} | messages]
  }

  case Req.post(@api_url,
         json: body,
         headers: [
           {"Authorization", "Bearer #{api_key()}"},
           {"HTTP-Referer", "https://scullion.gustafrydholm.xyz"},
           {"X-Title", "Tore"}
         ]
       ) do
    {:ok, %{status: 200, body: resp}} ->
      content = get_in(resp, ["choices", Access.at(0), "message", "content"])
      usage = extract_usage(resp)
      {:ok, content, usage}

    {:ok, %{status: 402}} ->
      {:error, :provider_budget_exceeded}

    {:ok, %{status: 429}} ->
      {:error, :rate_limited}

    {:ok, %{status: status, body: resp}} ->
      {:error, {:openrouter_error, status, resp}}

    {:error, reason} ->
      {:error, {:http_error, reason}}
  end
end
```

### Tests

```elixir
# test/tore/adapters/open_router_chat_test.exs
defmodule Tore.Adapters.OpenRouterChatTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  test "chat/2 returns string reply via MockLLM" do
    Tore.MockLLM
    |> expect(:chat, fn system, messages ->
      assert is_binary(system)
      assert [%{"role" => "user", "content" => "What can I cook tonight?"}] = messages
      {:ok, "Try pasta!", %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.0001}}
    end)

    assert {:ok, "Try pasta!", _usage} =
             Tore.MockLLM.chat("You are a cooking assistant.", [
               %{"role" => "user", "content" => "What can I cook tonight?"}
             ])
  end

  test "chat/2 propagates errors" do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} =
             Tore.MockLLM.chat("system", [%{"role" => "user", "content" => "hello"}])
  end
end
```

### Commit
```
jj describe -m "feat: add chat/2 callback to LLM behaviour and implement in OpenRouter adapter"
```

---

## Task 3 — `Tore.Chat.SystemPrompt`

### Files
- `lib/tore/chat/system_prompt.ex`
- `test/tore/chat/system_prompt_test.exs`

### Implementation

```elixir
# lib/tore/chat/system_prompt.ex
defmodule Tore.Chat.SystemPrompt do
  @moduledoc """
  Builds the system prompt for the chat assistant.
  Assembles static role text + household preferences + pantry snapshot + week context.
  """

  alias Tore.{Household, Pantry, WeekMode, EventStore, Planning.Decider}

  @spec build() :: String.t()
  def build do
    today = Date.utc_today()
    week_mode = WeekMode.get_current_mode()

    sections = [
      role_section(),
      date_section(today),
      dietary_section(),
      week_mode_section(week_mode),
      week_context_section(today),
      pantry_section()
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp role_section do
    """
    You are Tore, a friendly and practical AI cooking and meal planning assistant.
    Help the household plan meals, manage groceries, and make the most of what they have.
    Respond conversationally in the user's language. Be concise and warm.
    """
    |> String.trim()
  end

  defp date_section(today) do
    "Today is #{Calendar.strftime(today, "%A, %B %-d, %Y")}."
  end

  defp dietary_section do
    prefs = Household.get_preferences()
    guidance = Household.prefs_to_dietary_guidance(prefs)
    if guidance, do: "Household preferences: #{guidance}.", else: nil
  end

  defp week_mode_section("normal"), do: nil

  defp week_mode_section(mode) do
    fragment = WeekMode.mode_prompt_fragment(mode)
    if fragment, do: "Current week mode: #{fragment}", else: nil
  end

  defp week_context_section(today) do
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    plan_id = "plan:#{Date.to_iso8601(week_start)}"

    case EventStore.load(plan_id, Decider) do
      {:ok, state} -> format_plan_state(state, week_start)
      _ -> nil
    end
  end

  defp format_plan_state(state, week_start) do
    days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    lines =
      Enum.with_index(days, fn day_name, i ->
        date = Date.add(week_start, i)
        slot_key = "#{String.downcase(String.slice(day_name, 0..2))}_dinner"
        slot = Map.get(state.slots, slot_key)

        meal =
          cond do
            is_nil(slot) -> "empty"
            slot[:skipped] -> "skipped"
            slot[:leftover] -> "leftover"
            slot[:recipe_title] -> slot[:recipe_title]
            true -> "empty"
          end

        "  #{day_name} #{Date.to_iso8601(date)}: #{meal}"
      end)

    "This week's dinner plan:\n#{Enum.join(lines, "\n")}"
  rescue
    _ -> nil
  end

  defp pantry_section do
    items = Pantry.list_inventory()

    if items == [] do
      nil
    else
      names = items |> Enum.map(& &1.name) |> Enum.take(20) |> Enum.join(", ")
      "Pantry has: #{names}#{if length(items) > 20, do: " and #{length(items) - 20} more", else: ""}."
    end
  rescue
    _ -> nil
  end
end
```

### Tests

```elixir
# test/tore/chat/system_prompt_test.exs
defmodule Tore.Chat.SystemPromptTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "build/0 returns a non-empty string" do
    result = Tore.Chat.SystemPrompt.build()
    assert is_binary(result)
    assert byte_size(result) > 0
  end

  test "build/0 contains today's date" do
    today = Date.utc_today()
    result = Tore.Chat.SystemPrompt.build()
    year = Integer.to_string(today.year)
    assert result =~ year
  end

  test "build/0 contains the role text" do
    result = Tore.Chat.SystemPrompt.build()
    assert result =~ "Tore"
  end
end
```

### Commit
```
jj describe -m "feat: Tore.Chat.SystemPrompt — assembles system prompt from household prefs, week plan, pantry"
```

---

## Task 4 — `Tore.Chat.ChatHandler`

### Files
- `lib/tore/chat/chat_handler.ex`
- `test/tore/chat/chat_handler_test.exs`

### Implementation

```elixir
# lib/tore/chat/chat_handler.ex
defmodule Tore.Chat.ChatHandler do
  @moduledoc """
  Entry point for chat messages. Makes a single LLM call and logs to ai_operations.
  Returns {: ok, reply_text, nil} — action dispatch is a future extension.
  """

  alias Tore.{AiOperations, Chat.SystemPrompt}

  @llm Application.compile_env(:tore, :llm_client)

  @spec handle_text(String.t(), keyword()) ::
          {:ok, String.t(), nil} | {:error, term()}
  def handle_text(text, _opts \\ []) do
    system = SystemPrompt.build()
    messages = [%{"role" => "user", "content" => text}]
    correlation_id = generate_correlation_id()

    AiOperations.log(%{
      correlation_id: correlation_id,
      kind: "chat",
      payload: text
    })

    case @llm.chat(system, messages) do
      {:ok, reply, _usage} ->
        AiOperations.log(%{
          correlation_id: "#{correlation_id}:reply",
          kind: "chat_reply",
          payload: text,
          result: reply
        })

        {:ok, reply, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_correlation_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```

### Tests

```elixir
# test/tore/chat/chat_handler_test.exs
defmodule Tore.Chat.ChatHandlerTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "handle_text/1 returns reply from LLM" do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages ->
      {:ok, "Pasta sounds great!", %{prompt_tokens: 20, completion_tokens: 10, cost_usd: 0.0001}}
    end)

    assert {:ok, "Pasta sounds great!", nil} =
             Tore.Chat.ChatHandler.handle_text("What should I cook tonight?")
  end

  test "handle_text/1 logs to ai_operations" do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages ->
      {:ok, "Soup!", %{prompt_tokens: 5, completion_tokens: 3, cost_usd: 0.00001}}
    end)

    Tore.Chat.ChatHandler.handle_text("Something warm?")

    ops = Tore.Repo.all(Tore.AiOperations.AiOperation)
    kinds = Enum.map(ops, & &1.kind)
    assert "chat" in kinds
    assert "chat_reply" in kinds
  end

  test "handle_text/1 propagates LLM errors" do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} =
             Tore.Chat.ChatHandler.handle_text("hello")
  end
end
```

### Commit
```
jj describe -m "feat: Tore.Chat.ChatHandler — single LLM call, logs to ai_operations, returns reply"
```

---

## Task 5 — `ChatLive` + router entry

### Files
- `lib/tore_web/live/chat_live.ex`
- `lib/tore_web/router.ex` — add `/chat` route
- `test/tore_web/live/chat_live_test.exs`

### Router change

In `lib/tore_web/router.ex`, inside the `live_session :authenticated` block, add:

```elixir
live "/chat", ChatLive
```

### LiveView

```elixir
# lib/tore_web/live/chat_live.ex
defmodule ToreWeb.ChatLive do
  use ToreWeb, :live_view

  alias Tore.Chat.ChatHandler

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], input: "", loading: false)}
  end

  @impl true
  def handle_event("send_message", %{"message" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      messages = socket.assigns.messages ++ [%{role: :user, text: text}]
      send(self(), {:chat, text})
      {:noreply, assign(socket, messages: messages, input: "", loading: true)}
    end
  end

  @impl true
  def handle_info({:chat, text}, socket) do
    case ChatHandler.handle_text(text) do
      {:ok, reply, _action} ->
        messages = socket.assigns.messages ++ [%{role: :assistant, text: reply}]
        {:noreply, assign(socket, messages: messages, loading: false)}

      {:error, _reason} ->
        messages =
          socket.assigns.messages ++
            [%{role: :assistant, text: "Sorry, I couldn't process that. Please try again."}]

        {:noreply, assign(socket, messages: messages, loading: false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-dvh bg-white dark:bg-zinc-950">
      <%!-- Header --%>
      <div class="flex items-center gap-3 px-4 py-3 border-b border-zinc-100 dark:border-zinc-800">
        <.link navigate="/" class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <span class="font-semibold text-zinc-800 dark:text-zinc-100">Ask Tore</span>
      </div>

      <%!-- Message list --%>
      <div
        id="chat-messages"
        class="flex-1 overflow-y-auto px-4 py-4 space-y-4"
        phx-hook="ScrollToBottom"
      >
        <%= for msg <- @messages do %>
          <div class={[
            "flex",
            if(msg.role == :user, do: "justify-end", else: "justify-start")
          ]}>
            <div class={[
              "max-w-[80%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed",
              if(msg.role == :user,
                do: "bg-zinc-800 text-white dark:bg-zinc-100 dark:text-zinc-900",
                else: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-100"
              )
            ]}>
              <%= msg.text %>
            </div>
          </div>
        <% end %>
        <%= if @loading do %>
          <div class="flex justify-start">
            <div class="bg-zinc-100 dark:bg-zinc-800 rounded-2xl px-4 py-2.5">
              <span class="text-zinc-400 text-sm animate-pulse">Thinking…</span>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Input --%>
      <div class="px-4 py-3 border-t border-zinc-100 dark:border-zinc-800">
        <form phx-submit="send_message" class="flex items-center gap-2">
          <input
            type="text"
            name="message"
            value={@input}
            placeholder="Ask anything about meals, groceries…"
            autocomplete="off"
            class="flex-1 rounded-full border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-4 py-2.5 text-sm text-zinc-800 dark:text-zinc-100 placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-300 dark:focus:ring-zinc-600"
          />
          <button
            type="submit"
            disabled={@loading}
            class="flex-shrink-0 w-10 h-10 rounded-full bg-zinc-800 dark:bg-zinc-100 flex items-center justify-center disabled:opacity-40"
          >
            <.icon name="hero-paper-airplane" class="size-4 text-white dark:text-zinc-900" />
          </button>
        </form>
        <%!-- Photo attach stub --%>
        <button
          type="button"
          disabled
          class="mt-2 text-xs text-zinc-400 flex items-center gap-1 opacity-50 cursor-not-allowed"
        >
          <.icon name="hero-camera" class="size-3.5" /> Attach photo (coming soon)
        </button>
      </div>
    </div>
    """
  end
end
```

### Tests

```elixir
# test/tore_web/live/chat_live_test.exs
defmodule ToreWeb.ChatLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Tore.Accounts

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    %{user: user}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "mount renders empty chat", %{conn: conn, user: user} do
    conn = authed(conn, user)
    {:ok, _lv, html} = live(conn, "/chat")
    assert html =~ "Ask Tore"
    assert html =~ "Ask anything about meals"
  end

  test "sending a message appends user and assistant messages", %{conn: conn, user: user} do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages ->
      {:ok, "Try making pasta tonight!", %{prompt_tokens: 10, completion_tokens: 8, cost_usd: 0.0001}}
    end)

    conn = authed(conn, user)
    {:ok, lv, _html} = live(conn, "/chat")

    html =
      lv
      |> form("form", %{message: "What should I cook?"})
      |> render_submit()

    assert html =~ "What should I cook?"

    # Wait for async handle_info to fire
    :timer.sleep(200)
    html = render(lv)
    assert html =~ "Try making pasta tonight!"
  end
end
```

### Commit
```
jj describe -m "feat: ChatLive at /chat — full-screen chat sheet with async LLM replies"
```

---

## Task 6 — Wire FAB to `/chat` on PlannerLive

### Context

The FAB is rendered in `lib/tore_web/live/planner_live.ex`. Phase 3 added the FAB as a stub button element. Search for it with:

```
grep -n "fab\|FAB\|fixed.*bottom\|floating" lib/tore_web/live/planner_live.ex
```

If a Phase 3 FAB stub exists (a `<button>` or element with no `phx-click`), replace it with a `<.link navigate="/chat">` wrapper or add `phx-click="open_chat"` with a corresponding `handle_event` that does `{:noreply, push_navigate(socket, to: "/chat")}`.

If no FAB stub exists yet (Phase 3 may not have landed), add the following FAB to the bottom of the main planner template, just before the closing `</div>` of the root container:

```heex
<%!-- AI chat FAB --%>
<.link
  navigate="/chat"
  class="fixed bottom-6 right-4 z-50 w-14 h-14 rounded-full bg-zinc-800 dark:bg-zinc-100 shadow-lg flex items-center justify-center hover:bg-zinc-700 dark:hover:bg-zinc-200 transition-colors"
  aria-label="Ask Tore"
>
  <.icon name="hero-chat-bubble-left-ellipsis" class="size-6 text-white dark:text-zinc-900" />
</.link>
```

### No separate test needed

FAB navigation is covered by the existing `PlannerLiveTest` mount test — the FAB renders a `<.link>` which requires no event handler and no assertion beyond it being present in HTML. Add a single assertion to the existing `"renders the planner"` test (or the first mount test):

```elixir
assert html =~ "/chat"
```

### Commit
```
jj describe -m "feat: wire PlannerLive FAB to /chat"
```

---

## Checklist

- [ ] Task 1: migration + `AiOperation` schema + `Tore.AiOperations` context + tests pass
- [ ] Task 2: `chat/2` callback in `Tore.LLM` + `@impl` in `OpenRouter` + mock test passes
- [ ] Task 3: `Tore.Chat.SystemPrompt.build/0` + tests pass
- [ ] Task 4: `Tore.Chat.ChatHandler.handle_text/2` + tests pass
- [ ] Task 5: `ChatLive` + `/chat` route + tests pass
- [ ] Task 6: PlannerLive FAB navigates to `/chat`

## Notes

- `Tore.Household.get_preferences/0` never raises — returns `%Preferences{}` on nil row. Safe to call without rescue.
- `EventStore.load/2` can return `{:error, :not_found}` for a new week. `SystemPrompt` handles this gracefully.
- `Tore.Pantry.list_inventory/0` is defined at line 21 of `lib/tore/pantry.ex`. Returns `[]` if empty.
- `Tore.WeekMode.get_current_mode/0` returns `"normal"` as default — the `nil` clause in `mode_prompt_fragment` covers it.
- The existing private `chat/3` in `OpenRouter` remains private; the new public `chat/2` callback is a separate function.
- `Tore.MockLLM` is already defined in `test/support/mocks.ex` — adding the new `chat/2` callback to `Tore.LLM` automatically makes it available on the mock via Mox.
- No `ScrollToBottom` hook is required for tests — the `phx-hook` attribute is ignored in LiveView tests.
