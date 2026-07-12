# Phase 2 — Garage Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace disk-based photo handling with Garage (self-hosted S3-compatible) storage via ex_aws_s3. Recipe images, receipt scans, and pantry photos are uploaded to S3 buckets and their public URLs stored in the database. Disk writing is removed from `RecipeHandler`.

**Architecture:** Add `Tore.Storage` behaviour with `Tore.Storage.S3` and `Tore.Storage.Mock` implementations. The compile-time config key `:storage_client` selects the adapter. `RecipeHandler.generate_image/2` writes to S3 instead of disk. Receipt and pantry uploads remain LLM-only (binary is consumed, not stored). Test environment uses an Agent-backed in-memory Mock.

**Tech Stack:** Elixir, ex_aws 2.5, ex_aws_s3 2.5, hackney 1.20, sweet_xml 0.7, Garage (S3-compatible), behaviour-based mock (no Mox)

**Current state:**
- `recipes.image_path` and `receipts.image_path` already exist in the DB (no migration needed)
- `RecipeHandler.generate_image/2` writes binary to `priv/static/uploads/recipes/{id}.jpg` on disk, then stores `/uploads/recipes/{id}.jpg` as `image_path`
- No S3 client in `mix.exs`; `mox` already present for tests

---

## Task 1 — Add deps and config

**Files:** `mix.exs`, `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`

No tests required (config only). One commit.

### Steps

- [ ] Add to `mix.exs` `deps/0`:

```elixir
{:ex_aws, "~> 2.5"},
{:ex_aws_s3, "~> 2.5"},
{:hackney, "~> 1.20"},
{:sweet_xml, "~> 0.7"},
```

- [ ] Run `mix deps.get`

- [ ] In `config/config.exs`, add after the existing `config :tore` block:

```elixir
config :ex_aws,
  access_key_id: {:system, "GARAGE_ACCESS_KEY_ID"},
  secret_access_key: {:system, "GARAGE_SECRET_ACCESS_KEY"},
  region: "garage"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 3900,
  path_style: true
```

- [ ] In `config/dev.exs`, add:

```elixir
config :tore, :storage_client, Tore.Storage.S3
```

- [ ] In `config/test.exs`, add:

```elixir
config :tore, :storage_client, Tore.Storage.Mock
```

- [ ] In `config/runtime.exs`, inside the `if config_env() == :prod do` block, add:

```elixir
config :ex_aws,
  access_key_id: System.fetch_env!("GARAGE_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("GARAGE_SECRET_ACCESS_KEY"),
  region: "garage"

config :ex_aws, :s3,
  scheme: "http://",
  host: System.fetch_env!("GARAGE_HOST"),
  port: String.to_integer(System.get_env("GARAGE_PORT", "3900")),
  path_style: true

config :tore, :storage_client, Tore.Storage.S3
```

- [ ] Commit:

```
jj describe -m "feat: add ex_aws_s3 deps and Garage config"
jj new
```

---

## Task 2 — Storage behaviour, S3 adapter, Mock adapter, Buckets constants

**Files:**
- `lib/tore/storage.ex`
- `lib/tore/storage/s3.ex`
- `lib/tore/storage/mock.ex`
- `lib/tore/storage/buckets.ex`
- `test/tore/storage_mock_test.exs`

### Steps

- [ ] Create `lib/tore/storage.ex`:

```elixir
defmodule Tore.Storage do
  @callback put_object(bucket :: String.t(), key :: String.t(), body :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback get_object_url(bucket :: String.t(), key :: String.t()) :: String.t()

  @callback delete_object(bucket :: String.t(), key :: String.t()) :: :ok | {:error, term()}

  def client, do: Application.fetch_env!(:tore, :storage_client)
end
```

- [ ] Create `lib/tore/storage/buckets.ex`:

```elixir
defmodule Tore.Storage.Buckets do
  @recipes "tore-recipes"
  @receipts "tore-receipts"
  @uploads "tore-uploads"

  def recipes, do: @recipes
  def receipts, do: @receipts
  def uploads, do: @uploads

  def all, do: [@recipes, @receipts, @uploads]
end
```

- [ ] Create `lib/tore/storage/s3.ex`:

```elixir
defmodule Tore.Storage.S3 do
  @behaviour Tore.Storage

  @impl true
  def put_object(bucket, key, body, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    bucket
    |> ExAws.S3.put_object(key, body, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _} -> {:ok, get_object_url(bucket, key)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_object_url(bucket, key) do
    config = ExAws.Config.new(:s3)
    scheme = config[:scheme] || "http://"
    host = config[:host] || "localhost"
    port = config[:port] || 3900
    "#{scheme}#{host}:#{port}/#{bucket}/#{key}"
  end

  @impl true
  def delete_object(bucket, key) do
    bucket
    |> ExAws.S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] Create `lib/tore/storage/mock.ex`:

```elixir
defmodule Tore.Storage.Mock do
  @behaviour Tore.Storage

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def put_object(bucket, key, body, _opts \\ []) do
    Agent.update(__MODULE__, &Map.put(&1, {bucket, key}, body))
    {:ok, get_object_url(bucket, key)}
  end

  @impl true
  def get_object_url(bucket, key) do
    "http://mock-storage/#{bucket}/#{key}"
  end

  @impl true
  def delete_object(bucket, key) do
    Agent.update(__MODULE__, &Map.delete(&1, {bucket, key}))
    :ok
  end

  def get(bucket, key) do
    Agent.get(__MODULE__, &Map.get(&1, {bucket, key}))
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end
```

- [ ] Create `test/tore/storage_mock_test.exs`:

```elixir
defmodule Tore.StorageMockTest do
  use ExUnit.Case, async: false

  alias Tore.Storage.Mock
  alias Tore.Storage.Buckets

  setup do
    start_supervised!(Mock)
    :ok
  end

  test "put_object stores body and returns url" do
    body = "fake image binary"
    {:ok, url} = Mock.put_object(Buckets.recipes(), "recipes/1/abc.jpg", body)
    assert url == "http://mock-storage/tore-recipes/recipes/1/abc.jpg"
    assert Mock.get(Buckets.recipes(), "recipes/1/abc.jpg") == body
  end

  test "get_object_url returns consistent url" do
    url = Mock.get_object_url(Buckets.recipes(), "recipes/1/abc.jpg")
    assert url == "http://mock-storage/tore-recipes/recipes/1/abc.jpg"
  end

  test "delete_object removes stored entry" do
    Mock.put_object(Buckets.receipts(), "receipts/5/img.jpg", "data")
    assert Mock.get(Buckets.receipts(), "receipts/5/img.jpg") == "data"
    :ok = Mock.delete_object(Buckets.receipts(), "receipts/5/img.jpg")
    assert Mock.get(Buckets.receipts(), "receipts/5/img.jpg") == nil
  end

  test "reset clears all entries" do
    Mock.put_object(Buckets.uploads(), "x/y.jpg", "z")
    Mock.reset()
    assert Mock.get(Buckets.uploads(), "x/y.jpg") == nil
  end
end
```

- [ ] Run `mix test test/tore/storage_mock_test.exs` and confirm all pass.

- [ ] Commit:

```
jj describe -m "feat: Tore.Storage behaviour, S3/Mock adapters, Buckets constants"
jj new
```

---

## Task 3 — Wire storage into RecipeHandler; store S3 URL as image_path

**Context:** `RecipeHandler.generate_image/2` currently:
1. Creates `priv/static/uploads/recipes/` on disk
2. Writes binary to `{uploads_dir}/recipes/{id}.jpg`
3. Stores `/uploads/recipes/{id}.jpg` as `recipes.image_path`

After this task it will upload the binary to S3 and store the returned URL instead. The disk write is removed. `image_path` now holds a full `http://` URL.

**Files:**
- `lib/tore/handlers/recipe_handler.ex`
- `test/tore/handlers/recipe_handler_test.exs` (new or update)

### Steps

- [ ] Rewrite `RecipeHandler.generate_image/2` in `lib/tore/handlers/recipe_handler.ex`:

```elixir
@spec generate_image(Tore.Recipes.Recipe.t(), String.t() | nil) :: :ok | {:error, term()}
def generate_image(recipe, image_url) do
  storage = Tore.Storage.client()
  key = "recipes/#{recipe.id}/#{Ecto.UUID.generate()}.jpg"

  with {:ok, binary} <- fetch_or_generate(recipe, image_url),
       {:ok, url} <- storage.put_object(Tore.Storage.Buckets.recipes(), key, binary, content_type: "image/jpeg") do
    Tore.Repo.update_all(
      from(r in Tore.Recipes.Recipe, where: r.id == ^recipe.id),
      set: [image_path: url]
    )

    :ok
  end
end
```

- [ ] Remove the `uploads_dir` / `File.mkdir_p!` / `File.write` lines from the function (they are fully replaced above).

- [ ] Create `test/tore/handlers/recipe_handler_test.exs` (add to existing file if it exists):

```elixir
defmodule Tore.Handlers.RecipeHandlerTest do
  use Tore.DataCase, async: false

  import Tore.AccountsFixtures
  alias Tore.Handlers.RecipeHandler
  alias Tore.Storage.Mock

  setup do
    start_supervised!(Mock)
    :ok
  end

  test "generate_image/2 uploads binary to mock storage and updates image_path" do
    user = user_fixture()

    {:ok, recipe} =
      Tore.Recipes.create(%{
        title: "Test Recipe",
        created_by: user.id
      })

    # Stub LLM image gen by providing an explicit URL that @http can't fetch,
    # so we patch via image_gen mock returning a binary.
    # Instead, call generate_image with a preloaded recipe and verify side effects.
    # The mock image_gen_client must be configured in test.exs.
    # Here we verify the DB + storage after the call completes.

    # Call is async via Task.start in Recipes.create; invoke directly for test:
    recipe_loaded = Tore.Repo.preload(recipe, recipe_ingredients: :ingredient)
    :ok = RecipeHandler.generate_image(recipe_loaded, nil)

    updated = Tore.Repo.get!(Tore.Recipes.Recipe, recipe.id)
    assert updated.image_path =~ "http://mock-storage/tore-recipes/recipes/#{recipe.id}/"
  end
end
```

> **Note:** This test requires the mock `@image_gen_client` (configured via `config :tore, :image_gen_client`) to return `{:ok, <<binary>>}`. If the project's test config already stubs that, the test runs as-is. If not, check `config/test.exs` for `:image_gen_client` and ensure it returns a valid binary for `generate_food_image/2`.

- [ ] Run `mix test test/tore/handlers/recipe_handler_test.exs` and confirm pass.

- [ ] Commit:

```
jj describe -m "feat: upload recipe images to Garage S3 via Tore.Storage"
jj new
```

---

## Task 4 — Ensure buckets exist on application boot (dev/test only)

**Context:** In production, buckets are pre-created via Garage admin. In dev and test, call `ExAws.S3.put_bucket/2` for each bucket in `Tore.Storage.Buckets.all/0` during `Application.start/2`. Errors are logged, not raised.

**Files:**
- `lib/tore/storage/s3.ex` (add `ensure_buckets_exist/0`)
- `lib/tore/application.ex`

### Steps

- [ ] Add to `lib/tore/storage/s3.ex`:

```elixir
@spec ensure_buckets_exist() :: :ok
def ensure_buckets_exist do
  Enum.each(Tore.Storage.Buckets.all(), fn bucket ->
    case bucket |> ExAws.S3.put_bucket("garage") |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 409, _}} ->
        # BucketAlreadyOwnedByYou — fine
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Could not ensure S3 bucket #{bucket} exists: #{inspect(reason)}")
    end
  end)
end
```

- [ ] In `lib/tore/application.ex`, add after `Tore.Repo` starts (i.e., after the supervisor starts) but only in `:dev` env. Append to `start/2` before `Supervisor.start_link`:

```elixir
if Application.get_env(:tore, :env, :prod) in [:dev] do
  # Best-effort bucket creation — runs after supervisor starts
  Task.start(fn ->
    Process.sleep(500)
    Tore.Storage.S3.ensure_buckets_exist()
  end)
end
```

> **Note:** The `Process.sleep(500)` gives the OTP supervisor a moment to fully initialize before making HTTP calls. An alternative is to add it as a final step in `start/2` after the return, but a detached Task is simpler here.

- [ ] In `config/dev.exs`, ensure:

```elixir
config :tore, :env, :dev
```

- [ ] In `config/test.exs`, ensure:

```elixir
config :tore, :env, :test
```

- [ ] In `config/prod.exs` (or `runtime.exs`), no `:env` key is needed (default `:prod` skips bucket creation).

- [ ] No automated test for this task (best-effort side-effect on boot).

- [ ] Commit:

```
jj describe -m "feat: ensure Garage S3 buckets exist on dev boot"
jj new
```

---

## Summary

| Task | Files changed | Test? |
|------|--------------|-------|
| 1 — Deps + config | `mix.exs`, 4 config files | No |
| 2 — Storage layer | 4 new `lib/tore/storage/` files | Yes — `test/tore/storage_mock_test.exs` |
| 3 — RecipeHandler | `lib/tore/handlers/recipe_handler.ex` | Yes — recipe_handler_test |
| 4 — Boot bucket init | `lib/tore/storage/s3.ex`, `lib/tore/application.ex`, 2 config files | No |

After all tasks, `priv/static/uploads/` is no longer written to for recipe images. The `uploads_dir` config and `ToreWeb.Plugs.UploadsStatic` can be removed in a follow-up cleanup once receipt/pantry uploads are also confirmed to never persist to disk (they currently don't — binaries are only passed to the LLM).
