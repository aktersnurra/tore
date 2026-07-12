# Phase 6 — Kiosk UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the touchscreen kiosk UI — tonight's dinner prominent, preset action buttons, Ask Tore FAB.

**Architecture:** `KioskLive` at `/kiosk`, device-token authenticated. Reads plan state via `PlanningHandler.load_plan/1`. Preset buttons call existing handler functions. Kiosk chat is a restricted variant of `CookingLive`-style chat (inline prompt override).

**Tech Stack:** Elixir/Phoenix/LiveView, TailwindCSS (large touch targets, min-h-20 buttons), existing `PlanningHandler`, `Tore.Accounts.verify_device_token/1`.

**Key conventions from codebase:**
- `plan_id` is derived as `"plan:#{Date.to_iso8601(week_start)}"` where `week_start` is the Monday of the current week (`Date.add(today, -(dow - 1))`)
- `slot_key` format: `"#{day}_dinner"` e.g. `"mon_dinner"`, `"tue_dinner"`
- Slot shape: `%{recipe_id: id | nil, servings: n, skipped: bool, leftover: bool}`
- `PlanningHandler.skip_meal(plan_id, slot_key)` — returns `{:ok, events}`
- `PlanningHandler.load_plan(plan_id)` — returns `{:ok, %Planning.State{}}`
- Auth: `on_mount` hooks in `ToreWeb.Live.Auth`; device tokens verified via `Accounts.verify_device_token(raw_token)`
- Existing `live_session :authenticated` uses `on_mount: [{ToreWeb.Live.Auth, :require_authenticated}]`
- Tests use `Plug.Test.init_test_session(conn, %{user_id: user.id})` for user auth
- Device token cookie name: `"_tore_device_token"`

---

## Task 1 — Device-token `on_mount` hook + kiosk route

- [ ] **Read** `lib/tore_web/live/auth.ex` and `lib/tore/accounts.ex` (verify_device_token already done above).

- [ ] **Add** `on_mount(:require_device_token, ...)` to `lib/tore_web/live/auth.ex`:

  ```elixir
  def on_mount(:require_device_token, _params, session, socket) do
    case session["device_token"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      raw_token ->
        case Tore.Accounts.verify_device_token(raw_token) do
          {:ok, :kiosk} -> {:cont, socket}
          {:error, _} -> {:halt, redirect(socket, to: "/login")}
        end
    end
  end
  ```

- [ ] **Add** a `pipeline :require_device_token` plug in `lib/tore_web/router.ex` that stores the cookie into the session (or use a dedicated plug). The cleanest approach: add a new plug `ToreWeb.Plugs.DeviceAuth` that reads `conn.cookies["_tore_device_token"]` and puts it in the session as `"device_token"`, redirecting to `/login` on failure.

  ```elixir
  # lib/tore_web/plugs/device_auth.ex
  defmodule ToreWeb.Plugs.DeviceAuth do
    import Plug.Conn
    import Phoenix.Controller, only: [redirect: 2]
    alias Tore.Accounts

    @behaviour Plug
    @cookie "_tore_device_token"

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      raw = conn.cookies[@cookie]

      case Accounts.verify_device_token(raw) do
        {:ok, :kiosk} ->
          put_session(conn, "device_token", raw)

        {:error, _} ->
          conn |> redirect(to: "/login") |> halt()
      end
    end
  end
  ```

- [ ] **Add** pipeline and routes to `lib/tore_web/router.ex`:

  ```elixir
  pipeline :require_device_token do
    plug ToreWeb.Plugs.DeviceAuth
  end

  scope "/kiosk", ToreWeb do
    pipe_through [:browser, :require_device_token]

    live_session :kiosk,
      on_mount: [{ToreWeb.Live.Auth, :require_device_token}] do
      live "/", KioskLive
      live "/chat", KioskChatLive
    end
  end
  ```

- [ ] **Tests** in `test/tore_web/live/kiosk_live_test.exs`:
  - Unauthenticated request to `/kiosk` redirects to `/login`
  - Request with valid device token cookie mounts successfully

  ```elixir
  defmodule ToreWeb.KioskLiveTest do
    use ToreWeb.ConnCase, async: false
    import Phoenix.LiveViewTest
    alias Tore.Accounts

    setup do
      {:ok, raw_token} = Accounts.create_device_token("Kitchen tablet")
      %{raw_token: raw_token}
    end

    defp kiosk_conn(conn, raw_token) do
      conn
      |> Map.put(:cookies, %{"_tore_device_token" => raw_token})
      |> Plug.Test.init_test_session(%{"device_token" => raw_token})
    end

    test "unauthenticated request redirects", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/kiosk")
    end

    test "authenticated request mounts", %{conn: conn, raw_token: raw_token} do
      {:ok, _lv, html} = live(kiosk_conn(conn, raw_token), "/kiosk")
      assert html =~ "Tonight"
    end
  end
  ```

  > **Note:** Check whether `Accounts.create_device_token/1` exists. If not, add it to `lib/tore/accounts.ex`:
  >
  > ```elixir
  > def create_device_token(name) do
  >   raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  >   hash = sha256(raw)
  >   %DeviceToken{}
  >   |> DeviceToken.changeset(%{name: name, token_hash: hash})
  >   |> Repo.insert()
  >   |> case do
  >     {:ok, _} -> {:ok, raw}
  >     {:error, cs} -> {:error, cs}
  >   end
  > end
  > ```

- [ ] **Commit:** `jj describe -m "feat: kiosk device-token auth plug and route"`

---

## Task 2 — `KioskLive` mount + tonight's dinner card

- [ ] **Create** `lib/tore_web/live/kiosk_live.ex`:

  ```elixir
  defmodule ToreWeb.KioskLive do
    use ToreWeb, :live_view

    alias Tore.{Recipes, Handlers.PlanningHandler}
    alias Phoenix.PubSub

    @days ~w[mon tue wed thu fri sat sun]

    def mount(_params, _session, socket) do
      today = Date.utc_today()
      week_start = week_start(today)
      plan_id = plan_id(week_start)

      if connected?(socket) do
        PubSub.subscribe(Tore.PubSub, "plan")
      end

      {:ok, plan_state} = PlanningHandler.load_plan(plan_id)
      recipes = Recipes.list(sort: :alphabetical)

      tonight_slot_key = "#{day_abbr(today)}_dinner"
      tonight_slot = Map.get(plan_state.slots, tonight_slot_key)
      tonight_recipe = recipe_by_id(recipes, tonight_slot && tonight_slot.recipe_id)

      upcoming = upcoming_days(today, plan_state, recipes)

      {:ok,
       assign(socket,
         today: today,
         week_start: week_start,
         plan_id: plan_id,
         plan_state: plan_state,
         recipes: recipes,
         tonight_slot_key: tonight_slot_key,
         tonight_slot: tonight_slot,
         tonight_recipe: tonight_recipe,
         upcoming: upcoming,
         pantry_input: nil,
         flash_msg: nil
       )}
    end

    def handle_info({:events, _events}, socket) do
      {:ok, plan_state} = PlanningHandler.load_plan(socket.assigns.plan_id)
      tonight_slot = Map.get(plan_state.slots, socket.assigns.tonight_slot_key)
      tonight_recipe = recipe_by_id(socket.assigns.recipes, tonight_slot && tonight_slot.recipe_id)
      upcoming = upcoming_days(socket.assigns.today, plan_state, socket.assigns.recipes)

      {:noreply,
       assign(socket,
         plan_state: plan_state,
         tonight_slot: tonight_slot,
         tonight_recipe: tonight_recipe,
         upcoming: upcoming
       )}
    end

    # ---------- helpers ----------

    defp week_start(date) do
      dow = Date.day_of_week(date)
      Date.add(date, -(dow - 1))
    end

    defp plan_id(week_start), do: "plan:#{Date.to_iso8601(week_start)}"

    defp day_abbr(date) do
      Enum.at(@days, Date.day_of_week(date) - 1)
    end

    defp recipe_by_id(_recipes, nil), do: nil
    defp recipe_by_id(recipes, id), do: Enum.find(recipes, &(&1.id == id))

    defp upcoming_days(today, plan_state, recipes) do
      @days
      |> Enum.with_index(1)
      |> Enum.map(fn {day, i} ->
        date = Date.add(week_start(today), i - 1)
        slot_key = "#{day}_dinner"
        slot = Map.get(plan_state.slots, slot_key)
        recipe = recipe_by_id(recipes, slot && slot.recipe_id)
        %{day: day, date: date, slot_key: slot_key, slot: slot, recipe: recipe}
      end)
      |> Enum.reject(fn %{date: d} -> d == today end)
    end

    # ---------- render ----------

    def render(assigns) do
      ~H"""
      <div class="min-h-screen bg-stone-950 text-white flex flex-col p-6 gap-6">
        <!-- Tonight's dinner -->
        <section class="flex flex-col gap-3">
          <p class="text-stone-400 text-lg uppercase tracking-widest font-medium">Tonight</p>
          <%= if @tonight_recipe do %>
            <h1 class="text-5xl font-bold leading-tight"><%= @tonight_recipe.title %></h1>
          <% else %>
            <h1 class="text-5xl font-bold leading-tight text-stone-500">No meal planned</h1>
          <% end %>
          <!-- Photo placeholder -->
          <div class="rounded-2xl bg-stone-800 h-48 w-full flex items-center justify-center text-stone-600 text-sm">
            Photo
          </div>
        </section>

        <!-- Upcoming strip -->
        <section class="flex flex-col gap-2">
          <p class="text-stone-400 text-sm uppercase tracking-widest font-medium">Coming up</p>
          <div class="flex gap-3 overflow-x-auto pb-1">
            <%= for day <- @upcoming do %>
              <div class="flex-shrink-0 rounded-xl bg-stone-800 px-4 py-3 w-32">
                <p class="text-stone-400 text-xs uppercase"><%= String.capitalize(day.day) %></p>
                <p class="text-sm font-medium mt-1 line-clamp-2">
                  <%= if day.recipe, do: day.recipe.title, else: "—" %>
                </p>
              </div>
            <% end %>
          </div>
        </section>

        <!-- Preset action buttons -->
        <section class="grid grid-cols-2 gap-4">
          <.link navigate={"/recipes/#{@tonight_recipe && @tonight_recipe.id}"}
            class="rounded-2xl bg-amber-600 active:bg-amber-700 flex items-center justify-center text-center font-semibold text-lg min-h-20 px-4 py-4">
            What's the recipe?
          </.link>

          <button phx-click="swap_tonight"
            class="rounded-2xl bg-sky-700 active:bg-sky-800 flex items-center justify-center text-center font-semibold text-lg min-h-20 px-4 py-4">
            Swap tonight
          </button>

          <button phx-click="cooked_it"
            class="rounded-2xl bg-emerald-700 active:bg-emerald-800 flex items-center justify-center text-center font-semibold text-lg min-h-20 px-4 py-4">
            I cooked it ✓
          </button>

          <button phx-click="open_pantry_input"
            class="rounded-2xl bg-stone-700 active:bg-stone-600 flex items-center justify-center text-center font-semibold text-lg min-h-20 px-4 py-4">
            We're out of…
          </button>
        </section>

        <!-- "We're out of" inline input -->
        <%= if @pantry_input != nil do %>
          <form phx-submit="submit_pantry" class="flex gap-3">
            <input name="item" type="text" autofocus placeholder="Item name…"
              class="flex-1 rounded-xl bg-stone-800 px-4 py-4 text-lg outline-none focus:ring-2 focus:ring-amber-500" />
            <button type="submit"
              class="rounded-xl bg-amber-600 px-6 font-semibold text-lg">
              Done
            </button>
          </form>
        <% end %>

        <!-- Flash toast -->
        <%= if @flash_msg do %>
          <div class="fixed bottom-24 left-1/2 -translate-x-1/2 bg-stone-700 rounded-xl px-6 py-3 text-sm font-medium shadow-lg">
            <%= @flash_msg %>
          </div>
        <% end %>

        <!-- Ask Tore FAB -->
        <.link navigate="/kiosk/chat"
          class="fixed bottom-6 right-6 bg-amber-500 text-stone-950 rounded-full w-20 h-20 flex items-center justify-center shadow-xl text-sm font-bold text-center leading-tight active:bg-amber-400">
          Ask<br/>Tore
        </.link>
      </div>
      """
    end
  end
  ```

- [ ] **Tests** — renders with plan state (slot assigned + slot nil):
  - Mount renders "Tonight" heading
  - When `tonight_recipe` is nil, shows "No meal planned"
  - When recipe is assigned, shows recipe title in h1

- [ ] **Commit:** `jj describe -m "feat: KioskLive mount — tonight card and upcoming strip"`

---

## Task 3 — Preset action button handlers

- [ ] **Add** `handle_event` clauses to `kiosk_live.ex`:

  ```elixir
  def handle_event("swap_tonight", _params, socket) do
    case PlanningHandler.skip_meal(socket.assigns.plan_id, socket.assigns.tonight_slot_key) do
      {:ok, _events} ->
        {:noreply, assign(socket, flash_msg: "Tonight's meal swapped.")}

      {:error, _reason} ->
        {:noreply, assign(socket, flash_msg: "Could not swap — no meal assigned.")}
    end
  end

  def handle_event("cooked_it", _params, socket) do
    # Stub: mark done. Full implementation in Phase 7.
    {:noreply, assign(socket, flash_msg: "Marked as done!")}
  end

  def handle_event("open_pantry_input", _params, socket) do
    {:noreply, assign(socket, pantry_input: "")}
  end

  def handle_event("submit_pantry", %{"item" => item}, socket) do
    item = String.trim(item)
    msg = if item != "", do: "Noted: out of #{item}.", else: nil
    {:noreply, assign(socket, pantry_input: nil, flash_msg: msg)}
  end
  ```

  > `submit_pantry` is a stub for Phase 7 (pantry correction). It closes the input and shows a toast.

- [ ] **Auto-dismiss flash** — add a `handle_info(:clear_flash, ...)` and a `Process.send_after` in `swap_tonight` and `cooked_it`:

  ```elixir
  defp flash(socket, msg) do
    Process.send_after(self(), :clear_flash, 3000)
    assign(socket, flash_msg: msg)
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end
  ```

  Replace bare `assign(socket, flash_msg: ...)` with `flash(socket, ...)` everywhere.

- [ ] **Tests:**
  - `"swap_tonight"` with no recipe assigned → flash contains "Could not swap"
  - `"swap_tonight"` with assigned slot → `PlanningHandler.skip_meal` is called and flash shows
  - `"cooked_it"` → flash shows "Marked as done!"
  - `"open_pantry_input"` → `pantry_input` assign becomes `""`
  - `"submit_pantry"` with item → flash contains item name, `pantry_input` returns to nil

- [ ] **Commit:** `jj describe -m "feat: kiosk preset action buttons — swap, cooked, pantry stub"`

---

## Task 4 — Kiosk chat (`/kiosk/chat`)

The kiosk chat reuses the `CookingLive` / chat infrastructure. Because there is no `ChatLive` today, implement a minimal `KioskChatLive` that wires into the existing LLM client with a restricted system prompt.

- [ ] **Read** `lib/tore_web/live/cooking_live.ex` fully — note it handles cooking preferences, not a chat interface. The `/cooking` route is for household cooking profile settings. So `KioskChatLive` will be a standalone small LiveView, not a reuse of `CookingLive`.

- [ ] **Create** `lib/tore_web/live/kiosk_chat_live.ex`:

  ```elixir
  defmodule ToreWeb.KioskChatLive do
    use ToreWeb, :live_view

    @llm Application.compile_env(:tore, :llm_client)

    @system_prompt """
    You are a cooking assistant on a kitchen kiosk. Answer cooking questions only \
    (techniques, substitutions, timing, temperatures, ingredient questions). \
    Do not modify the meal plan or grocery list. Keep answers concise and practical.
    """

    def mount(_params, _session, socket) do
      {:ok,
       assign(socket,
         messages: [],
         input: "",
         loading: false
       )}
    end

    def handle_event("update_input", %{"value" => value}, socket) do
      {:noreply, assign(socket, input: value)}
    end

    def handle_event("send", %{"message" => message}, socket) do
      message = String.trim(message)

      if message == "" do
        {:noreply, socket}
      else
        messages = socket.assigns.messages ++ [%{role: "user", content: message}]

        send(self(), {:ask_llm, messages})

        {:noreply, assign(socket, messages: messages, input: "", loading: true)}
      end
    end

    def handle_info({:ask_llm, messages}, socket) do
      result = @llm.chat(@system_prompt, messages)

      case result do
        {:ok, reply, _usage} ->
          updated = messages ++ [%{role: "assistant", content: reply}]
          {:noreply, assign(socket, messages: updated, loading: false)}

        {:error, _reason} ->
          updated = messages ++ [%{role: "assistant", content: "Sorry, something went wrong."}]
          {:noreply, assign(socket, messages: updated, loading: false)}
      end
    end

    def render(assigns) do
      ~H"""
      <div class="min-h-screen bg-stone-950 text-white flex flex-col">
        <!-- Header -->
        <div class="flex items-center gap-4 px-6 py-4 border-b border-stone-800">
          <.link navigate="/kiosk" class="text-stone-400 text-2xl">←</.link>
          <h1 class="text-xl font-semibold">Ask Tore</h1>
        </div>

        <!-- Messages -->
        <div class="flex-1 overflow-y-auto px-6 py-4 flex flex-col gap-4">
          <%= for msg <- @messages do %>
            <div class={if msg.role == "user", do: "self-end bg-amber-600 rounded-2xl rounded-br-sm px-4 py-3 max-w-[80%]", else: "self-start bg-stone-800 rounded-2xl rounded-bl-sm px-4 py-3 max-w-[80%]"}>
              <p class="text-base leading-relaxed"><%= msg.content %></p>
            </div>
          <% end %>
          <%= if @loading do %>
            <div class="self-start bg-stone-800 rounded-2xl px-4 py-3">
              <p class="text-stone-400 text-sm">Thinking…</p>
            </div>
          <% end %>
        </div>

        <!-- Input -->
        <form phx-submit="send" class="flex gap-3 px-6 py-4 border-t border-stone-800">
          <input name="message" type="text" value={@input} placeholder="Ask a cooking question…"
            phx-change="update_input" phx-value-value=""
            class="flex-1 rounded-xl bg-stone-800 px-4 py-4 text-lg outline-none focus:ring-2 focus:ring-amber-500" />
          <button type="submit"
            class="rounded-xl bg-amber-500 text-stone-950 px-6 font-semibold text-lg min-h-14 active:bg-amber-400">
            Send
          </button>
        </form>
      </div>
      """
    end
  end
  ```

  > **Note:** The `@llm.chat/2` call assumes the LLM client has a `chat(system_prompt, messages)` function. Read `lib/tore/llm_client.ex` (or the behaviour) before implementing — adjust the call signature to match what exists. If only `generate_plan` / `suggest_recipes` exist, add a `chat/2` to the mock and real client.

- [ ] **Add route** (already in Task 1 skeleton): `live "/chat", KioskChatLive` under the `:kiosk` live_session.

- [ ] **Tests** in `test/tore_web/live/kiosk_chat_live_test.exs`:
  - Mounts and renders input form
  - Sending a message appends user bubble and triggers LLM call
  - LLM reply appears as assistant bubble

- [ ] **Commit:** `jj describe -m "feat: kiosk chat — restricted cooking-only assistant"`

---

## Implementation order

1. Task 1 (auth + route) — blocks everything else
2. Task 2 (mount + tonight card + upcoming strip) — can be done in same session
3. Task 3 (action buttons) — depends on Task 2
4. Task 4 (kiosk chat) — independent after Task 1

## Files created / modified

| File | Action |
|---|---|
| `lib/tore_web/plugs/device_auth.ex` | Create |
| `lib/tore_web/live/auth.ex` | Modify — add `on_mount(:require_device_token, ...)` |
| `lib/tore_web/router.ex` | Modify — add `:require_device_token` pipeline + `/kiosk` scope |
| `lib/tore/accounts.ex` | Modify — add `create_device_token/1` if missing |
| `lib/tore_web/live/kiosk_live.ex` | Create |
| `lib/tore_web/live/kiosk_chat_live.ex` | Create |
| `test/tore_web/live/kiosk_live_test.exs` | Create |
| `test/tore_web/live/kiosk_chat_live_test.exs` | Create |

## Open questions / risks

- **LLM client `chat/2`:** Verify the LLM behaviour module supports a generic `chat(system, messages)` call. If not, add it to the behaviour + mock before Task 4.
- **Recipe photo:** No photo field exists on recipes today. The photo placeholder in `KioskLive` is a `div` stub. Leave it; add real photos in a later phase.
- **`submit_pantry` stub:** Only shows a toast. Actual pantry stock reduction is a Phase 7 concern.
- **`cooked_it` stub:** Marking a slot as cooked is not modelled in events yet. Left as a toast stub.
- **Flash auto-dismiss:** Uses `Process.send_after` — acceptable for a kiosk that runs in a persistent tab.
