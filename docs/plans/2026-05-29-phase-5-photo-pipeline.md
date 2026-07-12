# Phase 5 — Photo Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify uploaded photos, group by class, route to structured pipelines, surface polymorphic review cards in chat.

**Architecture:** Each photo → `classify_image/1` LLM call → group by class → route group to pipeline → review card or in-chat action. Low confidence (< 0.6) triggers a disambiguation message. Review cards in `ChatLive` navigate to `/review/:class/:id` rendered by a polymorphic `ReviewLive`.

**Tech Stack:** Elixir, Phoenix LiveView, Mox (`Tore.MockLLM` already defined in `test/support/mocks.ex`), `ex_aws_s3` for temp uploads (Phase 2 `Tore.Storage` assumed available)

**Current state:**
- `lib/tore/llm.ex` has `@callback classify_grocery_item/1` but no `classify_image/1`
- `lib/tore/adapters/open_router.ex` already has `vision_model/0` helper and vision call pattern (see `parse_receipt_image/1` at line 57, `parse_pantry_image/1` at line 118, `parse_recipe_images/2` at line 419)
- `lib/tore/recipes.ex` has `extract_from_images/2` → delegates to `@llm.parse_recipe_images/2`
- `lib/tore/handlers/pantry_handler.ex` has `parse_image/1` + `confirm_items/1`
- `lib/tore/handlers/costs_handler.ex` has `parse_receipt_image/1` + `confirm_receipt/2`
- `ChatLive` and `ReviewLive` do not yet exist (Phase 4 adds `ChatLive`)
- Router has no `/review` route
- `Tore.MockLLM` is `Mox.defmock(Tore.MockLLM, for: Tore.LLM)` — adding the callback extends the mock automatically

---

## Task 1 — `@callback classify_image/1` in LLM + OpenRouter implementation

**Files touched:**
- `lib/tore/llm.ex`
- `lib/tore/adapters/open_router.ex`
- `test/tore/adapters/open_router_classify_image_test.exs` (new)

**No migration needed.**

### Steps

- [ ] Add callback to `lib/tore/llm.ex` after `classify_grocery_item/1`:

```elixir
@callback classify_image(image :: binary()) ::
  {:ok, %{class: :receipt | :recipe | :pantry_items | :fridge | :unknown, confidence: float()}}
  | {:error, term()}
```

- [ ] Add `@impl Tore.LLM` implementation to `lib/tore/adapters/open_router.ex` using the existing vision call pattern:

```elixir
@impl Tore.LLM
def classify_image(image_binary) do
  system = """
  You are an image classifier for a meal planning app.
  Classify the image into exactly one of these categories: receipt, recipe, pantry_items, fridge, unknown.
  - receipt: a store receipt or invoice with line items and prices
  - recipe: a recipe card, cookbook page, or handwritten recipe
  - pantry_items: individual food products, cans, boxes, ingredients on a shelf or counter
  - fridge: an open fridge or freezer showing its contents
  - unknown: anything else
  Return JSON only: {"class": "<one of the five values>", "confidence": <0.0-1.0>}
  """

  user_text = "Classify this image."
  b64 = Base.encode64(image_binary)

  body = %{
    model: vision_model(),
    messages: [
      %{role: "system", content: system},
      %{
        role: "user",
        content: [
          %{type: "text", text: user_text},
          %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,#{b64}"}}
        ]
      }
    ]
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

      with {:ok, %{"class" => cls, "confidence" => conf}} <- Jason.decode(content),
           class_atom when class_atom != nil <- parse_image_class(cls) do
        {:ok, %{class: class_atom, confidence: conf}}
      else
        _ -> {:ok, %{class: :unknown, confidence: 0.0}}
      end

    {:ok, %{status: 402}} -> {:error, :provider_budget_exceeded}
    {:ok, %{status: 429}} -> {:error, :rate_limited}
    {:ok, %{status: status, body: resp}} -> {:error, {:openrouter_error, status, resp}}
    {:error, reason} -> {:error, {:http_error, reason}}
  end
end

defp parse_image_class("receipt"), do: :receipt
defp parse_image_class("recipe"), do: :recipe
defp parse_image_class("pantry_items"), do: :pantry_items
defp parse_image_class("fridge"), do: :fridge
defp parse_image_class(_), do: :unknown
```

- [ ] Add test `test/tore/adapters/open_router_classify_image_test.exs`:

```elixir
defmodule Tore.Adapters.OpenRouterClassifyImageTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "classify_image mock returns recipe class" do
    Tore.MockLLM
    |> expect(:classify_image, fn _binary ->
      {:ok, %{class: :recipe, confidence: 0.9}}
    end)

    assert {:ok, %{class: :recipe, confidence: 0.9}} =
             Tore.MockLLM.classify_image(<<"fake_image_binary">>)
  end

  test "classify_image mock returns unknown for low-confidence result" do
    Tore.MockLLM
    |> expect(:classify_image, fn _binary ->
      {:ok, %{class: :unknown, confidence: 0.4}}
    end)

    assert {:ok, %{class: :unknown, confidence: conf}} =
             Tore.MockLLM.classify_image(<<"fake_image_binary">>)

    assert conf < 0.6
  end
end
```

- [ ] Commit: `jj describe -m "feat: add classify_image/1 callback and OpenRouter implementation"`

---

## Task 2 — `Tore.PhotoPipeline`

**Files touched:**
- `lib/tore/photo_pipeline.ex` (new)
- `test/tore/photo_pipeline_test.exs` (new)

**No migration needed.**

The pipeline classifies each binary concurrently, groups by class, and routes:
- `:recipe` → `Tore.Recipes.extract_from_images/2`
- `:receipt` → `Tore.Handlers.CostsHandler.parse_receipt_image/1` (returns parsed items for review, does NOT save)
- `:pantry_items` → `Tore.Handlers.PantryHandler.parse_image/1` (returns items for review, does NOT save)
- `:fridge` → returns `{:ok, :fridge_contents, items}` — fridge suggestions are generated in chat, not in a review card
- `:unknown` or confidence < 0.6 → `{:ok, :ambiguous}`

`process_uploads/2` returns `{:ok, [%{class, status, result}]}`, one entry per class group.

### Steps

- [ ] Create `lib/tore/photo_pipeline.ex`:

```elixir
defmodule Tore.PhotoPipeline do
  @llm Application.compile_env(:tore, :llm_client)

  @confidence_threshold 0.6

  @type class :: :receipt | :recipe | :pantry_items | :fridge | :unknown
  @type pipeline_result :: %{
          class: class(),
          status: :ok | :ambiguous,
          result: term()
        }

  @spec process_uploads([binary()], String.t()) ::
          {:ok, [pipeline_result()]} | {:error, term()}
  def process_uploads(binaries, _correlation_id) when is_list(binaries) do
    classified =
      binaries
      |> Task.async_stream(&classify_one/1, timeout: 30_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, {:ok, result}} -> [result]
        _ -> []
      end)

    groups =
      classified
      |> Enum.group_by(& &1.class)

    results =
      groups
      |> Enum.map(fn {class, entries} ->
        images = Enum.map(entries, & &1.binary)
        route_group(class, images)
      end)

    {:ok, results}
  end

  defp classify_one(binary) do
    case @llm.classify_image(binary) do
      {:ok, %{class: class, confidence: conf}} when conf >= @confidence_threshold ->
        {:ok, %{class: class, binary: binary}}

      {:ok, _low_confidence} ->
        {:ok, %{class: :unknown, binary: binary}}

      {:error, _} ->
        {:ok, %{class: :unknown, binary: binary}}
    end
  end

  defp route_group(:recipe, images) do
    case Tore.Recipes.extract_from_images(images) do
      {:ok, recipe} -> %{class: :recipe, status: :ok, result: recipe}
      {:error, reason} -> %{class: :recipe, status: :error, result: reason}
    end
  end

  defp route_group(:receipt, [image | _]) do
    case Tore.Handlers.CostsHandler.parse_receipt_image(image) do
      {:ok, parsed} -> %{class: :receipt, status: :ok, result: parsed}
      {:error, reason} -> %{class: :receipt, status: :error, result: reason}
    end
  end

  defp route_group(:pantry_items, [image | _]) do
    case Tore.Handlers.PantryHandler.parse_image(image) do
      {:ok, items, _usage} -> %{class: :pantry_items, status: :ok, result: items}
      {:error, reason} -> %{class: :pantry_items, status: :error, result: reason}
    end
  end

  defp route_group(:fridge, [image | _]) do
    case Tore.Handlers.PantryHandler.parse_image(image) do
      {:ok, items, _usage} -> %{class: :fridge, status: :ok, result: items}
      {:error, reason} -> %{class: :fridge, status: :error, result: reason}
    end
  end

  defp route_group(:unknown, _images) do
    %{class: :unknown, status: :ambiguous, result: nil}
  end
end
```

- [ ] Create `test/tore/photo_pipeline_test.exs`:

```elixir
defmodule Tore.PhotoPipelineTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  @recipe_binary <<"recipe_image">>
  @receipt_binary <<"receipt_image">>

  test "groups 2 recipe images + 1 receipt image into 2 groups" do
    Tore.MockLLM
    |> expect(:classify_image, fn @recipe_binary ->
      {:ok, %{class: :recipe, confidence: 0.95}}
    end)
    |> expect(:classify_image, fn @recipe_binary ->
      {:ok, %{class: :recipe, confidence: 0.88}}
    end)
    |> expect(:classify_image, fn @receipt_binary ->
      {:ok, %{class: :receipt, confidence: 0.91}}
    end)
    |> expect(:parse_recipe_images, fn _images, _locale ->
      {:ok, %{title: "Pasta", ingredients: [], instructions: "Cook it"}}
    end)
    |> expect(:parse_receipt_for_pantry, fn _binary ->
      {:ok, %{total: Decimal.new("12.50"), store_name: "ICA", items: []}, %{}}
    end)

    assert {:ok, results} =
             Tore.PhotoPipeline.process_uploads(
               [@recipe_binary, @recipe_binary, @receipt_binary],
               "test-correlation-id"
             )

    assert length(results) == 2
    classes = Enum.map(results, & &1.class) |> Enum.sort()
    assert classes == [:receipt, :recipe]
  end

  test "low-confidence image returns ambiguous group" do
    Tore.MockLLM
    |> expect(:classify_image, fn _binary ->
      {:ok, %{class: :receipt, confidence: 0.4}}
    end)

    assert {:ok, [%{class: :unknown, status: :ambiguous}]} =
             Tore.PhotoPipeline.process_uploads([<<"blurry">>], "corr-1")
  end
end
```

- [ ] Commit: `jj describe -m "feat: PhotoPipeline — classify, group, and route uploaded photos"`

---

## Task 3 — Wire PhotoPipeline into ChatLive

**Files touched:**
- `lib/tore_web/live/chat_live.ex` (Phase 4 file — extend, do not rewrite)
- `test/tore_web/live/chat_live_photo_test.exs` (new)

**Assumption:** Phase 4 adds `ChatLive` with an `allow_upload(:chat_photos, ...)` socket assignment and a submit handler. This task extends that handler.

### Steps

- [ ] In `ChatLive`, after the existing text-only path in the submit handler, add a photo branch:

```elixir
# Collect uploaded photo binaries
photo_binaries =
  consume_uploaded_entries(socket, :chat_photos, fn %{path: path}, _entry ->
    {:ok, File.read!(path)}
  end)

# If photos were attached, run the pipeline asynchronously
if photo_binaries != [] do
  correlation_id = Ecto.UUID.generate()
  pid = self()

  Task.start(fn ->
    result = Tore.PhotoPipeline.process_uploads(photo_binaries, correlation_id)
    send(pid, {:pipeline_complete, result})
  end)

  {:noreply, assign(socket, :processing_photos, true)}
else
  # existing text-only path
  ...
end
```

- [ ] Add `handle_info/2` for `:pipeline_complete` in `ChatLive`:

```elixir
def handle_info({:pipeline_complete, {:ok, results}}, socket) do
  messages =
    Enum.map(results, fn
      %{class: :unknown, status: :ambiguous} ->
        %{type: :text, role: :assistant,
          content: "I wasn't sure what that photo showed. Could you tell me — is it a receipt, a recipe, or your fridge?"}

      %{class: :fridge, status: :ok, result: items} ->
        suggestion = fridge_suggestion_text(items)
        %{type: :text, role: :assistant, content: suggestion}

      %{class: class, status: :ok, result: result} ->
        review_id = store_review(class, result)
        %{type: :review_card, role: :assistant, class: class, review_id: review_id}

      %{class: class, status: :error} ->
        %{type: :text, role: :assistant,
          content: "Something went wrong processing the #{class} photo. Try again?"}
    end)

  {:noreply,
   socket
   |> assign(:processing_photos, false)
   |> update(:chat_messages, &(&1 ++ messages))}
end

def handle_info({:pipeline_complete, {:error, _}}, socket) do
  {:noreply,
   socket
   |> assign(:processing_photos, false)
   |> put_flash(:error, "Photo processing failed.")}
end
```

- [ ] Add `store_review/2` private function (stores result in ETS or process state keyed by a UUID; returns the UUID):

```elixir
defp store_review(class, result) do
  id = Ecto.UUID.generate()
  :ets.insert(:chat_reviews, {id, %{class: class, result: result}})
  id
end
```

- [ ] Add ETS table init in `ChatLive.mount/3`:

```elixir
:ets.new(:chat_reviews, [:set, :public, :named_table])
```

  Note: use `:ets.whereis/1` to avoid re-creating on reconnects:

```elixir
if :ets.whereis(:chat_reviews) == :undefined do
  :ets.new(:chat_reviews, [:set, :public, :named_table])
end
```

- [ ] Add `fridge_suggestion_text/1` private helper:

```elixir
defp fridge_suggestion_text([]), do: "I can see your fridge but it looks empty. Add some items to get recipe suggestions."
defp fridge_suggestion_text(items) do
  names = items |> Enum.map(& &1.name) |> Enum.take(5) |> Enum.join(", ")
  "I can see #{names} in your fridge. Want me to suggest some recipes?"
end
```

- [ ] In the `ChatLive` HEEx template, render review card messages:

```heex
<%= for msg <- @chat_messages do %>
  <%= if msg.type == :review_card do %>
    <div class="chat-review-card">
      <p>I found a <%= msg.class %>. Ready to review?</p>
      <.link navigate={~p"/review/#{msg.class}/#{msg.review_id}"} class="btn-primary">
        Review
      </.link>
    </div>
  <% else %>
    <div class={"chat-msg chat-msg--#{msg.role}"}>
      <%= msg.content %>
    </div>
  <% end %>
<% end %>
```

- [ ] Create `test/tore_web/live/chat_live_photo_test.exs`:

```elixir
defmodule ToreWeb.ChatLivePhotoTest do
  use ToreWeb.ConnCase, async: false
  import Mox
  import Phoenix.LiveViewTest

  setup :verify_on_exit!

  test "submitting a photo attachment triggers pipeline and shows review card", %{conn: conn} do
    Tore.MockLLM
    |> expect(:classify_image, fn _binary ->
      {:ok, %{class: :recipe, confidence: 0.92}}
    end)
    |> expect(:parse_recipe_images, fn _images, _locale ->
      {:ok, %{title: "Pasta Carbonara", ingredients: [], instructions: "Cook pasta."}}
    end)

    {:ok, view, _html} = live(conn, ~p"/chat")

    # Simulate photo upload + submit
    view
    |> file_input("#chat-form", :chat_photos, [
      %{name: "recipe.jpg", content: "fake_binary", type: "image/jpeg"}
    ])

    view |> element("#chat-form") |> render_submit()

    # Wait for async pipeline
    assert render(view) =~ "Review"
    assert render(view) =~ "recipe"
  end

  test "unknown class shows disambiguation message", %{conn: conn} do
    Tore.MockLLM
    |> expect(:classify_image, fn _binary ->
      {:ok, %{class: :unknown, confidence: 0.3}}
    end)

    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> file_input("#chat-form", :chat_photos, [
      %{name: "blurry.jpg", content: "fake_binary", type: "image/jpeg"}
    ])

    view |> element("#chat-form") |> render_submit()

    assert render(view) =~ "wasn't sure"
  end
end
```

- [ ] Commit: `jj describe -m "feat: wire PhotoPipeline into ChatLive with review cards and disambiguation"`

---

## Task 4 — `ReviewLive` + router + recipe review

**Files touched:**
- `lib/tore_web/live/review_live.ex` (new)
- `lib/tore_web/router.ex`
- `test/tore_web/live/review_live_recipe_test.exs` (new)

### Steps

- [ ] Add route to `lib/tore_web/router.ex` inside the authenticated `live_session :authenticated` block:

```elixir
live "/review/:class/:id", ReviewLive
```

- [ ] Create `lib/tore_web/live/review_live.ex`:

```elixir
defmodule ToreWeb.ReviewLive do
  use ToreWeb, :live_view

  @impl true
  def mount(%{"class" => class, "id" => id}, _session, socket) do
    review = fetch_review(id)

    if review == nil do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       assign(socket,
         class: String.to_existing_atom(class),
         review_id: id,
         result: review.result,
         saved: false
       )}
    end
  end

  @impl true
  def handle_event("confirm", _params, %{assigns: %{class: :recipe}} = socket) do
    case save_recipe(socket.assigns.result, socket.assigns.current_user) do
      {:ok, _recipe} -> {:noreply, assign(socket, :saved, true)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save recipe.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="review-container">
      <%= render_review(assigns) %>
    </div>
    """
  end

  defp render_review(%{class: :recipe} = assigns) do
    ~H"""
    <h2 class="review-title"><%= @result[:title] || @result["title"] || "Untitled Recipe" %></h2>
    <%= unless @saved do %>
      <p class="review-unsaved">Nothing saved yet.</p>
    <% end %>
    <div class="review-body">
      <section>
        <h3>Ingredients</h3>
        <ul>
          <%= for ing <- (@result[:ingredients] || @result["ingredients"] || []) do %>
            <li><%= ing[:name] || ing["name"] %></li>
          <% end %>
        </ul>
      </section>
      <section>
        <h3>Instructions</h3>
        <p><%= @result[:instructions] || @result["instructions"] %></p>
      </section>
    </div>
    <%= unless @saved do %>
      <button phx-click="confirm" class="btn-primary">Confirm & Save</button>
    <% else %>
      <p class="review-saved-badge">Saved to your recipe catalog.</p>
    <% end %>
    """
  end

  defp render_review(%{class: class} = assigns) when class in [:receipt, :pantry_items] do
    ~H"""
    <p>Review for <%= @class %> — see Tasks 5 and 6.</p>
    """
  end

  defp fetch_review(id) do
    case :ets.lookup(:chat_reviews, id) do
      [{^id, review}] -> review
      [] -> nil
    end
  end

  defp save_recipe(result, _user) do
    attrs = %{
      title: result[:title] || result["title"],
      instructions: result[:instructions] || result["instructions"],
      servings: result[:servings] || result["servings"],
      ingredients: result[:ingredients] || result["ingredients"] || []
    }

    Tore.Recipes.create_from_map(attrs)
  end
end
```

  Note: `Tore.Recipes.create_from_map/1` may not exist yet. If absent, use `Tore.Recipes.create_recipe/1` or whatever the Phase 1 context exposes — check `lib/tore/recipes.ex` before implementing and adapt.

- [ ] Create `test/tore_web/live/review_live_recipe_test.exs`:

```elixir
defmodule ToreWeb.ReviewLiveRecipeTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    # Seed the ETS table with a review entry
    if :ets.whereis(:chat_reviews) == :undefined do
      :ets.new(:chat_reviews, [:set, :public, :named_table])
    end

    id = Ecto.UUID.generate()
    recipe = %{title: "Lasagne", ingredients: [%{name: "pasta"}], instructions: "Layer it."}
    :ets.insert(:chat_reviews, {id, %{class: :recipe, result: recipe}})
    %{review_id: id}
  end

  test "renders recipe review with title and ingredients", %{conn: conn, review_id: id} do
    {:ok, _view, html} = live(conn, ~p"/review/recipe/#{id}")
    assert html =~ "Lasagne"
    assert html =~ "pasta"
    assert html =~ "Nothing saved yet"
  end

  test "confirm saves recipe and shows saved badge", %{conn: conn, review_id: id} do
    {:ok, view, _html} = live(conn, ~p"/review/recipe/#{id}")
    view |> element("button", "Confirm & Save") |> render_click()
    assert render(view) =~ "Saved to your recipe catalog"
  end
end
```

- [ ] Commit: `jj describe -m "feat: ReviewLive with recipe review, confirm saves to catalog"`

---

## Task 5 — Receipt review in `ReviewLive`

**Files touched:**
- `lib/tore_web/live/review_live.ex`
- `test/tore_web/live/review_live_receipt_test.exs` (new)

**Context:** Receipt data from `CostsHandler.parse_receipt_image/1` returns `{:ok, %{total: Decimal.t() | nil, store_name: String.t() | nil, items: [map()]}}`. Confirm calls `CostsHandler.confirm_receipt/2`.

### Steps

- [ ] Add `handle_event("confirm", ...)` clause for `:receipt` in `ReviewLive`:

```elixir
def handle_event("confirm", _params, %{assigns: %{class: :receipt}} = socket) do
  attrs = %{
    total: socket.assigns.result[:total] || socket.assigns.result["total"],
    store_name: socket.assigns.result[:store_name] || socket.assigns.result["store_name"],
    items: socket.assigns.result[:items] || socket.assigns.result["items"] || [],
    date: Date.utc_today()
  }

  case Tore.Handlers.CostsHandler.confirm_receipt(attrs, socket.assigns.current_user.id) do
    {:ok, _} -> {:noreply, assign(socket, :saved, true)}
    {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save receipt.")}
  end
end
```

- [ ] Add receipt render clause to `render_review/1`:

```elixir
defp render_review(%{class: :receipt} = assigns) do
  ~H"""
  <h2 class="review-title">Receipt</h2>
  <%= if @result[:store_name] || @result["store_name"] do %>
    <p class="review-meta">Store: <%= @result[:store_name] || @result["store_name"] %></p>
  <% end %>
  <%= unless @saved do %>
    <p class="review-unsaved">Nothing saved yet.</p>
  <% end %>
  <table class="review-line-items">
    <thead>
      <tr><th>Item</th><th>Qty</th><th>Price</th></tr>
    </thead>
    <tbody>
      <%= for item <- (@result[:items] || @result["items"] || []) do %>
        <tr>
          <td><%= item[:product_name] || item["product_name"] %></td>
          <td><%= item[:quantity] || item["quantity"] %></td>
          <td><%= item[:total_price] || item["total_price"] %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
  <%= unless @saved do %>
    <button phx-click="confirm" class="btn-primary">Confirm & Save</button>
  <% else %>
    <p class="review-saved-badge">Saved to costs.</p>
  <% end %>
  """
end
```

- [ ] Create `test/tore_web/live/review_live_receipt_test.exs`:

```elixir
defmodule ToreWeb.ReviewLiveReceiptTest do
  use ToreWeb.ConnCase, async: false
  import Mox
  import Phoenix.LiveViewTest

  setup :verify_on_exit!

  setup do
    if :ets.whereis(:chat_reviews) == :undefined do
      :ets.new(:chat_reviews, [:set, :public, :named_table])
    end

    id = Ecto.UUID.generate()
    receipt = %{
      total: Decimal.new("42.00"),
      store_name: "Willys",
      items: [%{product_name: "Mjölk", quantity: Decimal.new(2), total_price: Decimal.new("4.50")}]
    }
    :ets.insert(:chat_reviews, {id, %{class: :receipt, result: receipt}})
    %{review_id: id}
  end

  test "renders receipt line items", %{conn: conn, review_id: id} do
    {:ok, _view, html} = live(conn, ~p"/review/receipt/#{id}")
    assert html =~ "Willys"
    assert html =~ "Mjölk"
    assert html =~ "Nothing saved yet"
  end

  test "confirm saves to costs", %{conn: conn, review_id: id} do
    {:ok, view, _html} = live(conn, ~p"/review/receipt/#{id}")
    view |> element("button", "Confirm & Save") |> render_click()
    assert render(view) =~ "Saved to costs"
  end
end
```

- [ ] Commit: `jj describe -m "feat: receipt review in ReviewLive — line items table, confirm saves to costs"`

---

## Task 6 — Pantry items review in `ReviewLive`

**Files touched:**
- `lib/tore_web/live/review_live.ex`
- `test/tore_web/live/review_live_pantry_test.exs` (new)

**Context:** Pantry items from `PantryHandler.parse_image/1` returns `[%{name, quantity, unit, category}]`. Confirm calls `PantryHandler.confirm_items/1`.

### Steps

- [ ] Add `handle_event("confirm", ...)` clause for `:pantry_items`:

```elixir
def handle_event("confirm", _params, %{assigns: %{class: :pantry_items}} = socket) do
  case Tore.Handlers.PantryHandler.confirm_items(socket.assigns.result) do
    {:ok, _items} -> {:noreply, assign(socket, :saved, true)}
    {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to add pantry items.")}
  end
end
```

- [ ] Add pantry items render clause to `render_review/1`:

```elixir
defp render_review(%{class: :pantry_items} = assigns) do
  ~H"""
  <h2 class="review-title">Pantry Items</h2>
  <%= unless @saved do %>
    <p class="review-unsaved">Nothing saved yet.</p>
  <% end %>
  <ul class="review-pantry-list">
    <%= for item <- (@result || []) do %>
      <li>
        <%= item[:name] || item["name"] %>
        — <%= item[:quantity] || item["quantity"] %> <%= item[:unit] || item["unit"] %>
      </li>
    <% end %>
  </ul>
  <%= unless @saved do %>
    <button phx-click="confirm" class="btn-primary">Confirm & Add to Pantry</button>
  <% else %>
    <p class="review-saved-badge">Added to pantry.</p>
  <% end %>
  """
end
```

- [ ] Create `test/tore_web/live/review_live_pantry_test.exs`:

```elixir
defmodule ToreWeb.ReviewLivePantryTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    if :ets.whereis(:chat_reviews) == :undefined do
      :ets.new(:chat_reviews, [:set, :public, :named_table])
    end

    id = Ecto.UUID.generate()
    items = [
      %{name: "Tomater", quantity: Decimal.new(4), unit: "st", category: "produce"},
      %{name: "Grädde", quantity: Decimal.new("0.5"), unit: "l", category: "dairy"}
    ]
    :ets.insert(:chat_reviews, {id, %{class: :pantry_items, result: items}})
    %{review_id: id}
  end

  test "renders pantry items list", %{conn: conn, review_id: id} do
    {:ok, _view, html} = live(conn, ~p"/review/pantry_items/#{id}")
    assert html =~ "Tomater"
    assert html =~ "Grädde"
    assert html =~ "Nothing saved yet"
  end

  test "confirm adds items to pantry", %{conn: conn, review_id: id} do
    {:ok, view, _html} = live(conn, ~p"/review/pantry_items/#{id}")
    view |> element("button", "Confirm & Add to Pantry") |> render_click()
    assert render(view) =~ "Added to pantry"
  end
end
```

- [ ] Commit: `jj describe -m "feat: pantry items review in ReviewLive — item list, confirm adds to pantry"`

---

## Implementation notes

**ETS review store:** Using a named ETS table (`:chat_reviews`) for temp review state is simple and avoids a migration, but it does not survive node restarts. If the app restarts mid-review, the user returns to an empty review page and is redirected home. This is acceptable for Phase 5. Phase 7 (family memory) can promote persistent review state if needed.

**`Tore.Recipes.create_from_map/1`:** Check `lib/tore/recipes.ex` before implementing Task 4. If the function doesn't exist, use the existing recipe creation function. If it takes an Ecto changeset form, adapt accordingly — do not create a new wrapper unless truly needed.

**`CostsHandler.parse_receipt_image/1` return shape:** The existing function at line 4 of `costs_handler.ex` delegates to `@llm.parse_receipt_for_pantry/1` which returns `{:ok, %{total, store_name, items}, usage}`. The pipeline stores the map directly. `confirm_receipt/2` at line 27 expects `%{total, store_name, items, date}`.

**Vision model default:** `google/gemini-2.5-flash-lite` (see `open_router.ex` line 728). Classification prompts are cheap; no separate model config needed.

**Temp Garage uploads:** The spec calls for uploading to `tore-uploads` before classification. This is deferred to a follow-up — the pipeline currently operates on in-memory binaries. Add `Tore.Storage.upload_temp/2` before classification and `Tore.Storage.move_to_permanent/2` after confirm if Garage is live from Phase 2.

**`fridge` class:** No review card is produced for fridge photos. The pipeline returns items and `ChatLive` renders a fridge suggestion text message inline. If the user wants recipes from fridge contents, they ask the chat assistant (Phase 4 text command path).
