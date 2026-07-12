# AI-First Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign Tore into an AI-first meal planning app with a cooking-mode home screen, unified FAB+chat assistant with photo classification, Family tenant model, Garage object storage, and longitudinal family memory.

**Architecture:** The existing Decider+handler+CRUD architecture is preserved entirely. New work is: (1) nuke DB and replace `Household`/`User` with `Family`/`User` tenant model, (2) add Garage object storage via `ex_aws_s3`, (3) rebuild the home screen as tonight+week strip, (4) build the FAB chat assistant as a LiveView component that issues commands against existing handlers using a risk-tiered action model and an AIOperation correlation layer, (5) add photo classification pipeline with per-image confidence scores routing to the chat, (6) add per-record `family_insights` table with weekly Quantum job that synthesises planning events into NL memory injected into every planning prompt.

**Tech Stack:** Elixir/Phoenix/LiveView, SQLite3, ex_aws + ex_aws_s3 (Garage S3), OpenRouter vision LLM (existing), Quantum scheduler (existing), TailwindCSS (existing)

---

## Scope overview

This plan is split into 8 phases. Each phase produces working, testable software:

- **Phase 1** — Nuke DB, Family model, fresh migrations
- **Phase 2** — Garage object storage
- **Phase 3** — Home screen (tonight + week strip)
- **Phase 4** — FAB + chat assistant (text commands)
- **Phase 5** — Photo classification pipeline in chat
- **Phase 6** — Kiosk layout (slim, cooking-only)
- **Phase 7** — Family memory (insights synthesis + prompt injection)
- **Phase 8** — AI-native UX primitives (counter notes, week modes, plan health, week repair, cascade map, contextual command bar, cooking substitution, cook mode)

---

## Phase 1 — Family Model & Fresh Database

### Task 1.1: Nuke the database and drop all old migrations

**Files:**
- Delete: `priv/repo/migrations/*.exs` (all existing)
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Stop the running server if needed**

```bash
mix phx.server  # Ctrl+C to stop
```

- [ ] **Step 2: Drop the database**

```bash
mix ecto.drop
```

Expected: `The database for Tore.Repo has been dropped`

- [ ] **Step 3: Delete all existing migration files**

```bash
rm priv/repo/migrations/*.exs
```

- [ ] **Step 4: Verify clean state**

```bash
ls priv/repo/migrations/
```

Expected: only `.formatter.exs` remains.

- [ ] **Step 5: Commit**

```bash
jj describe -m "chore: nuke db and remove old migrations for fresh start"
```

---

### Task 1.2: Create the Family schema and migration

**Files:**
- Create: `lib/tore/family.ex`
- Create: `lib/tore/family/family_schema.ex`
- Create: `priv/repo/migrations/20260528000001_create_families.exs`

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260528000001_create_families.exs
defmodule Tore.Repo.Migrations.CreateFamilies do
  use Ecto.Migration

  def change do
    create table(:families) do
      add :name, :string, null: false
      add :locale, :string, null: false, default: "sv"
      timestamps()
    end
  end
end
```

- [ ] **Step 2: Write the Ecto schema**

```elixir
# lib/tore/family/family_schema.ex
defmodule Tore.Family.FamilySchema do
  use Ecto.Schema
  import Ecto.Changeset

  schema "families" do
    field :name, :string
    field :locale, :string, default: "sv"
    has_many :users, Tore.Accounts.User
    timestamps()
  end

  def changeset(family, attrs) do
    family
    |> cast(attrs, [:name, :locale])
    |> validate_required([:name, :locale])
    |> validate_inclusion(:locale, ["sv", "en"])
  end
end
```

- [ ] **Step 3: Write the Family context module**

```elixir
# lib/tore/family.ex
defmodule Tore.Family do
  alias Tore.{Repo, Family.FamilySchema}
  import Ecto.Query

  @spec get_family() :: FamilySchema.t() | nil
  def get_family, do: Repo.one(FamilySchema)

  @spec get_family!() :: FamilySchema.t()
  def get_family!, do: Repo.one!(FamilySchema)

  @spec create_family(map()) :: {:ok, FamilySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_family(attrs), do: %FamilySchema{} |> FamilySchema.changeset(attrs) |> Repo.insert()

  @spec update_family(FamilySchema.t(), map()) :: {:ok, FamilySchema.t()} | {:error, Ecto.Changeset.t()}
  def update_family(family, attrs), do: family |> FamilySchema.changeset(attrs) |> Repo.update()

  @spec locale() :: String.t()
  def locale do
    case get_family() do
      nil -> "sv"
      f -> f.locale
    end
  end
end
```

- [ ] **Step 4: Write a test**

```elixir
# test/tore/family_test.exs
defmodule Tore.FamilyTest do
  use Tore.DataCase, async: true

  alias Tore.Family

  test "create_family/1 creates a family with default locale" do
    assert {:ok, family} = Family.create_family(%{name: "Rydholm"})
    assert family.name == "Rydholm"
    assert family.locale == "sv"
  end

  test "locale/0 returns sv when no family exists" do
    assert Family.locale() == "sv"
  end

  test "locale/0 returns family locale when family exists" do
    {:ok, _} = Family.create_family(%{name: "Test", locale: "en"})
    assert Family.locale() == "en"
  end
end
```

- [ ] **Step 5: Run the test — expect failure (no migration run yet)**

```bash
mix test test/tore/family_test.exs
```

Expected: error about missing `families` table.

- [ ] **Step 6: Run the migration and re-run test**

```bash
mix ecto.create && mix ecto.migrate && mix test test/tore/family_test.exs
```

Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(family): add Family schema, context, and migration"
```

---

### Task 1.3: Update User schema — add family_id, remove locale

**Files:**
- Modify: `lib/tore/accounts/user.ex`
- Create: `priv/repo/migrations/20260528000002_create_users.exs`

- [ ] **Step 1: Write the users migration**

```elixir
# priv/repo/migrations/20260528000002_create_users.exs
defmodule Tore.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :account_code_hash, :string, null: false
      add :role, :string, null: false, default: "member"
      add :preferences, :map, default: %{}
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:users, [:family_id])
  end
end
```

- [ ] **Step 2: Update the User schema**

```elixir
# lib/tore/accounts/user.ex
defmodule Tore.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :account_code_hash, :string
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :preferences, :map, default: %{}
    belongs_to :family, Tore.Family.FamilySchema
    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :role, :account_code_hash, :family_id])
    |> validate_required([:name, :role, :account_code_hash, :family_id])
    |> validate_length(:name, min: 1, max: 100)
  end

  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:preferences])
    |> validate_required([:preferences])
  end
end
```

- [ ] **Step 3: Update `Tore.Accounts.create_user/1` to require `family_id`**

Open `lib/tore/accounts.ex`. Find `create_user/1`. Change so it also passes `family_id` from attrs:

```elixir
def create_user(attrs) do
  %User{}
  |> User.registration_changeset(attrs)
  |> Repo.insert()
end
```

No change needed to the function body itself — `registration_changeset` now casts `family_id`. Just ensure callers pass it.

- [ ] **Step 4: Update `setup_live.ex` to create family first, then user**

Open `lib/tore_web/live/setup_live.ex`. Find the `handle_event("submit", ...)` handler. Update it to:

```elixir
def handle_event("submit", %{"name" => name}, socket) do
  with {:ok, family} <- Tore.Family.create_family(%{name: name, locale: "sv"}),
       code <- generate_code(),
       {:ok, _user} <- Tore.Accounts.create_user(%{
         name: name,
         role: :admin,
         account_code_hash: Argon2.hash_pwd_salt(code),
         family_id: family.id
       }) do
    {:noreply, assign(socket, :code, code)}
  else
    {:error, _} -> {:noreply, put_flash(socket, :error, "Setup failed")}
  end
end
```

- [ ] **Step 5: Run migrations and full test suite**

```bash
mix ecto.reset && mix test
```

Expected: all tests pass (some may need fixing for `family_id` — fix inline).

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(family): add family_id to users, update setup flow"
```

---

### Task 1.4: Replace Household with Family — migrate preferences to Family

The existing `Household.Preferences` is a singleton preference record. These preferences belong on the `Family`. We'll add the preference fields directly to the `families` table.

**Files:**
- Delete: `lib/tore/household.ex`
- Delete: `lib/tore/household/preferences.ex`
- Modify: `lib/tore/family/family_schema.ex`
- Modify: `lib/tore/family.ex`
- Modify: `priv/repo/migrations/20260528000001_create_families.exs` (expand families columns)

- [ ] **Step 1: Update the families migration to include preference columns**

Replace `priv/repo/migrations/20260528000001_create_families.exs` with:

```elixir
defmodule Tore.Repo.Migrations.CreateFamilies do
  use Ecto.Migration

  def change do
    create table(:families) do
      add :name, :string, null: false
      add :locale, :string, null: false, default: "sv"
      add :dietary_restrictions, {:array, :string}, default: []
      add :allergies, {:array, :string}, default: []
      add :dislikes, {:array, :string}, default: []
      add :cooking_style, {:array, :string}, default: []
      add :cuisine_preferences, :map, default: %{}
      add :default_portions, :integer, default: 4
      add :default_leftover_portions, :integer, default: 2
      add :include_lunches, :boolean, default: false
      add :planning_days, :integer, default: 5
      timestamps()
    end
  end
end
```

- [ ] **Step 2: Update the FamilySchema to include preference fields**

```elixir
# lib/tore/family/family_schema.ex
defmodule Tore.Family.FamilySchema do
  use Ecto.Schema
  import Ecto.Changeset

  schema "families" do
    field :name, :string
    field :locale, :string, default: "sv"
    field :dietary_restrictions, {:array, :string}, default: []
    field :allergies, {:array, :string}, default: []
    field :dislikes, {:array, :string}, default: []
    field :cooking_style, {:array, :string}, default: []
    field :cuisine_preferences, :map, default: %{}
    field :default_portions, :integer, default: 4
    field :default_leftover_portions, :integer, default: 2
    field :include_lunches, :boolean, default: false
    field :planning_days, :integer, default: 5
    has_many :users, Tore.Accounts.User
    timestamps()
  end

  @preference_fields ~w(dietary_restrictions allergies dislikes cooking_style
    cuisine_preferences default_portions default_leftover_portions
    include_lunches planning_days)a

  def changeset(family, attrs) do
    family
    |> cast(attrs, [:name, :locale | @preference_fields])
    |> validate_required([:name, :locale])
    |> validate_inclusion(:locale, ["sv", "en"])
    |> validate_number(:default_portions, greater_than: 0)
    |> validate_number(:default_leftover_portions, greater_than_or_equal_to: 0)
    |> validate_inclusion(:planning_days, [5, 7])
  end
end
```

- [ ] **Step 3: Add preference helpers to `Tore.Family`**

Add to `lib/tore/family.ex`:

```elixir
  @preference_fields ~w(dietary_restrictions allergies dislikes cooking_style
    cuisine_preferences default_portions default_leftover_portions
    include_lunches planning_days)a

  @spec update_preferences(map()) :: {:ok, FamilySchema.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(attrs) do
    get_family!() |> FamilySchema.changeset(attrs) |> Repo.update()
  end

  @spec prefs_to_dietary_guidance(FamilySchema.t()) :: String.t() | nil
  def prefs_to_dietary_guidance(%FamilySchema{} = f) do
    parts =
      [
        restrictions_line(f.dietary_restrictions),
        allergies_line(f.allergies),
        dislikes_line(f.dislikes),
        style_line(f.cooking_style),
        cuisine_line(f.cuisine_preferences)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, "; ")
  end

  defp restrictions_line([]), do: nil
  defp restrictions_line(nil), do: nil
  defp restrictions_line(list), do: "Diet: #{Enum.join(list, ", ")}"

  defp allergies_line([]), do: nil
  defp allergies_line(nil), do: nil
  defp allergies_line(list), do: "Allergies/hard avoids: #{Enum.join(list, ", ")}"

  defp dislikes_line([]), do: nil
  defp dislikes_line(nil), do: nil
  defp dislikes_line(list), do: "Avoid too often: #{Enum.join(list, ", ")}"

  defp style_line([]), do: nil
  defp style_line(nil), do: nil
  defp style_line(list), do: "Cooking style: #{Enum.join(list, ", ")}"

  defp cuisine_line(nil), do: nil
  defp cuisine_line(map) when map == %{}, do: nil
  defp cuisine_line(map) do
    more = map |> Enum.filter(fn {_, v} -> v == "more" end) |> Enum.map(&elem(&1, 0))
    less = map |> Enum.filter(fn {_, v} -> v == "less" end) |> Enum.map(&elem(&1, 0))
    [if(more != [], do: "More of: #{Enum.join(more, ", ")}"),
     if(less != [], do: "Less of: #{Enum.join(less, ", ")}")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> "Cuisine: #{Enum.join(parts, "; ")}"
    end
  end
```

- [ ] **Step 4: Update `cooking_live.ex` — replace `Household` calls with `Family`**

In `lib/tore_web/live/cooking_live.ex`, replace all `Tore.Household` references with `Tore.Family`, and `Household.Preferences` struct field accesses with `FamilySchema` (same field names, so only the alias changes).

Change the top alias line:
```elixir
alias Tore.Family
```

Change `mount/3`:
```elixir
def mount(_params, _session, socket) do
  family = Family.get_family!()
  {:ok, assign(socket, prefs: family, dislike_input: "", saved: false)}
end
```

Change `save_and_assign/3` (the private helper):
```elixir
defp save_and_assign(socket, attrs, extra \\ []) do
  family = socket.assigns.prefs
  full_attrs = Map.merge(prefs_to_map(family), attrs)

  case Family.update_preferences(full_attrs) do
    {:ok, updated} ->
      assigns = [prefs: updated, saved: true] ++ extra
      {:noreply, assign(socket, assigns)}
    {:error, _} ->
      {:noreply, socket}
  end
end
```

- [ ] **Step 5: Delete the old Household modules**

```bash
rm lib/tore/household.ex lib/tore/household/preferences.ex
rmdir lib/tore/household
```

- [ ] **Step 6: Search for remaining `Household` references and fix them**

```bash
grep -r "Household" lib/ test/
```

Fix each occurrence: replace `Tore.Household` with `Tore.Family`, `Household.Preferences` struct with `Tore.Family.FamilySchema`.

- [ ] **Step 7: Run full test suite**

```bash
mix ecto.reset && mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(family): replace Household with Family, migrate preferences to family row"
```

---

### Task 1.5: Remaining migrations — events, device_tokens, recipes, deals, pantry, costs, prep

**Files:**
- Create: `priv/repo/migrations/20260528000003_create_events.exs`
- Create: `priv/repo/migrations/20260528000004_create_device_tokens.exs`
- Create: `priv/repo/migrations/20260528000005_create_recipes.exs`
- Create: `priv/repo/migrations/20260528000006_create_ingredients.exs`
- Create: `priv/repo/migrations/20260528000007_create_recipe_ingredients.exs`
- Create: `priv/repo/migrations/20260528000008_create_tags.exs`
- Create: `priv/repo/migrations/20260528000009_create_recipe_tags.exs`
- Create: `priv/repo/migrations/20260528000010_create_deals.exs`
- Create: `priv/repo/migrations/20260528000011_create_store_configs.exs`
- Create: `priv/repo/migrations/20260528000012_create_pantry_items.exs`
- Create: `priv/repo/migrations/20260528000013_create_receipts.exs`
- Create: `priv/repo/migrations/20260528000014_create_line_items.exs`
- Create: `priv/repo/migrations/20260528000015_create_dining_out.exs`
- Create: `priv/repo/migrations/20260528000016_create_prep_guides.exs`
- Create: `priv/repo/migrations/20260528000017_create_household_preferences.exs` — SKIP (absorbed into families)
- Create: `priv/repo/migrations/20260528000018_create_llm_usage.exs`

- [ ] **Step 1: Create events migration**

```elixir
# priv/repo/migrations/20260528000003_create_events.exs
defmodule Tore.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :stream_id, :string, null: false
      add :stream_type, :string, null: false
      add :event_type, :string, null: false
      add :data, :text, null: false
      add :metadata, :text
      add :inserted_at, :utc_datetime, null: false, default: fragment("(datetime('now'))")
    end

    create index(:events, [:stream_id, :id])
  end
end
```

- [ ] **Step 2: Create device_tokens migration**

```elixir
# priv/repo/migrations/20260528000004_create_device_tokens.exs
defmodule Tore.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :token_hash, :string, null: false
      add :name, :string, null: false
      add :revoked_at, :utc_datetime
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:device_tokens, [:token_hash])
  end
end
```

- [ ] **Step 3: Create recipes migration**

```elixir
# priv/repo/migrations/20260528000005_create_recipes.exs
defmodule Tore.Repo.Migrations.CreateRecipes do
  use Ecto.Migration

  def change do
    create table(:recipes) do
      add :title, :string, null: false
      add :description, :text
      add :instructions, :text
      add :steps, {:array, :map}, default: []
      add :recipe_type, :string, default: "meal"
      add :base_servings, :integer, default: 4
      add :prep_time_minutes, :integer
      add :cook_time_minutes, :integer
      add :source_url, :string
      add :video_url, :string
      add :image_key, :string
      add :last_used_at, :utc_datetime
      add :created_by, references(:users, on_delete: :nilify_all)
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:recipes, [:family_id])
    create index(:recipes, [:last_used_at])
  end
end
```

- [ ] **Step 4: Create ingredients migration**

```elixir
# priv/repo/migrations/20260528000006_create_ingredients.exs
defmodule Tore.Repo.Migrations.CreateIngredients do
  use Ecto.Migration

  def change do
    create table(:ingredients) do
      add :name, :string, null: false
      add :key, :string
      add :category, :string
      add :default_unit, :string
      timestamps()
    end

    create unique_index(:ingredients, [:name])
  end
end
```

- [ ] **Step 5: Create recipe_ingredients migration**

```elixir
# priv/repo/migrations/20260528000007_create_recipe_ingredients.exs
defmodule Tore.Repo.Migrations.CreateRecipeIngredients do
  use Ecto.Migration

  def change do
    create table(:recipe_ingredients) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :ingredient_id, references(:ingredients, on_delete: :delete_all), null: false
      add :quantity, :decimal
      add :unit, :string
      add :notes, :string
      timestamps()
    end

    create index(:recipe_ingredients, [:recipe_id])
    create index(:recipe_ingredients, [:ingredient_id])
  end
end
```

- [ ] **Step 6: Create tags and recipe_tags migrations**

```elixir
# priv/repo/migrations/20260528000008_create_tags.exs
defmodule Tore.Repo.Migrations.CreateTags do
  use Ecto.Migration

  def change do
    create table(:tags) do
      add :name, :string, null: false
      timestamps()
    end

    create unique_index(:tags, [:name])
  end
end
```

```elixir
# priv/repo/migrations/20260528000009_create_recipe_tags.exs
defmodule Tore.Repo.Migrations.CreateRecipeTags do
  use Ecto.Migration

  def change do
    create table(:recipe_tags, primary_key: false) do
      add :recipe_id, references(:recipes, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:recipe_tags, [:recipe_id, :tag_id])
  end
end
```

- [ ] **Step 7: Create deals and store_configs migrations**

```elixir
# priv/repo/migrations/20260528000010_create_deals.exs
defmodule Tore.Repo.Migrations.CreateDeals do
  use Ecto.Migration

  def change do
    create table(:deals) do
      add :store, :string
      add :chain, :string
      add :store_location, :string
      add :product_name, :string, null: false
      add :brand, :string
      add :size, :string
      add :price, :decimal
      add :regular_price, :decimal
      add :price_unit, :string
      add :offer_condition, :string
      add :valid_from, :date
      add :valid_until, :date
      add :source, :string, default: "scraped"
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:deals, [:family_id])
    create unique_index(:deals, [:family_id, :store, :product_name, :valid_from])
  end
end
```

```elixir
# priv/repo/migrations/20260528000011_create_store_configs.exs
defmodule Tore.Repo.Migrations.CreateStoreConfigs do
  use Ecto.Migration

  def change do
    create table(:store_configs) do
      add :name, :string, null: false
      add :chain, :string
      add :store_id, :string
      add :url, :string
      add :scrape_enabled, :boolean, default: true
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:store_configs, [:family_id])
  end
end
```

- [ ] **Step 8: Create pantry_items migration**

```elixir
# priv/repo/migrations/20260528000012_create_pantry_items.exs
defmodule Tore.Repo.Migrations.CreatePantryItems do
  use Ecto.Migration

  def change do
    create table(:pantry_items) do
      add :name, :string, null: false
      add :quantity, :decimal
      add :unit, :string
      add :category, :string
      add :confidence, :string, null: false, default: "confirmed"
      add :ingredient_id, references(:ingredients, on_delete: :nilify_all)
      add :added_at, :utc_datetime
      add :expires_at, :date
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:pantry_items, [:family_id])
  end
end
```

- [ ] **Step 9: Create costs migrations**

```elixir
# priv/repo/migrations/20260528000013_create_receipts.exs
defmodule Tore.Repo.Migrations.CreateReceipts do
  use Ecto.Migration

  def change do
    create table(:receipts) do
      add :date, :date
      add :store_name, :string
      add :total_amount, :decimal
      add :image_key, :string
      add :user_id, references(:users, on_delete: :nilify_all)
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:receipts, [:family_id])
  end
end
```

```elixir
# priv/repo/migrations/20260528000014_create_line_items.exs
defmodule Tore.Repo.Migrations.CreateLineItems do
  use Ecto.Migration

  def change do
    create table(:line_items) do
      add :receipt_id, references(:receipts, on_delete: :delete_all), null: false
      add :product_name, :string
      add :quantity, :decimal
      add :unit_price, :decimal
      add :total_price, :decimal
      add :category, :string
      timestamps()
    end

    create index(:line_items, [:receipt_id])
  end
end
```

```elixir
# priv/repo/migrations/20260528000015_create_dining_out.exs
defmodule Tore.Repo.Migrations.CreateDiningOut do
  use Ecto.Migration

  def change do
    create table(:dining_out) do
      add :date, :date
      add :description, :string
      add :total_amount, :decimal
      add :num_people, :integer
      add :user_id, references(:users, on_delete: :nilify_all)
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:dining_out, [:family_id])
  end
end
```

- [ ] **Step 10: Create prep_guides migration**

```elixir
# priv/repo/migrations/20260528000016_create_prep_guides.exs
defmodule Tore.Repo.Migrations.CreatePrepGuides do
  use Ecto.Migration

  def change do
    create table(:prep_guides) do
      add :week_start, :date, null: false
      add :instructions, :text
      add :timeline, :text
      add :components, :text
      add :cascade_map, :text
      add :storage_notes, :text
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:prep_guides, [:family_id, :week_start])
  end
end
```

- [ ] **Step 11: Create llm_usage migration**

```elixir
# priv/repo/migrations/20260528000017_create_llm_usage.exs
defmodule Tore.Repo.Migrations.CreateLlmUsage do
  use Ecto.Migration

  def change do
    create table(:llm_usage) do
      add :operation, :string, null: false
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :total_tokens, :integer
      add :model, :string
      add :family_id, references(:families, on_delete: :delete_all)
      timestamps()
    end
  end
end
```

- [ ] **Step 11b: Create ai_operations migration**

The `ai_operations` table records every AI action with a `correlation_id` for idempotency and a pre-computed `undo_operation_id` pointer for CRUD undo (pantry adds, grocery adds) that don't have a compensating event in the event store.

```elixir
# priv/repo/migrations/20260528000018_create_ai_operations.exs
defmodule Tore.Repo.Migrations.CreateAiOperations do
  use Ecto.Migration

  def change do
    create table(:ai_operations) do
      add :correlation_id, :string, null: false
      add :kind, :string, null: false
      add :payload, :text
      add :result, :text
      add :undo_op_id, :integer
      add :family_id, references(:families, on_delete: :delete_all), null: false
      timestamps(updated_at: false)
    end

    create unique_index(:ai_operations, [:correlation_id])
    create index(:ai_operations, [:family_id])
  end
end
```

- [ ] **Step 12: Update schemas that need `family_id`**

For each schema that touches shared family data, add `belongs_to :family, Tore.Family.FamilySchema` and `family_id` to its changeset. Affected schemas:
- `lib/tore/deals/deal.ex` — add `belongs_to :family`
- `lib/tore/deals/store_config.ex` — add `belongs_to :family`
- `lib/tore/pantry/pantry_item.ex` — add `belongs_to :family`
- `lib/tore/costs/receipt.ex` — add `belongs_to :family`
- `lib/tore/costs/dining_out.ex` — add `belongs_to :family`
- `lib/tore/prep/prep_guide.ex` — add `belongs_to :family`
- `lib/tore/recipes/recipe.ex` — add `belongs_to :family`, change `image_path` to `image_key`

For each schema, add:
```elixir
belongs_to :family, Tore.Family.FamilySchema
```
And add `:family_id` to the cast/validate fields in the changeset.

- [ ] **Step 13: Update context modules to scope queries by family**

For each context (`Deals`, `Pantry`, `Costs`, `Prep`, `Recipes`), update queries to filter by `family_id`. Use `Tore.Family.get_family!().id` to get the current family ID. Example for `Pantry`:

```elixir
def list_inventory do
  family_id = Tore.Family.get_family!().id
  Repo.all(from p in PantryItem, where: p.family_id == ^family_id)
end
```

Apply the same pattern to: `Deals.list_current/0`, `Recipes.list/1`, `Costs.log_receipt/1`, `Prep.get_guide_for_week/1`.

- [ ] **Step 14: Run full reset and test suite**

```bash
mix ecto.reset && mix test
```

Fix any remaining compilation or test failures.

- [ ] **Step 15: Commit**

```bash
jj describe -m "feat(db): fresh migrations with family scoping on all tables"
```

---

## Phase 2 — Garage Object Storage

### Task 2.1: Add ex_aws dependencies

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Add deps to mix.exs**

In the `deps/0` function, add:

```elixir
{:ex_aws, "~> 2.5"},
{:ex_aws_s3, "~> 2.5"},
{:sweet_xml, "~> 0.7"},
{:hackney, "~> 1.18"},
```

- [ ] **Step 2: Fetch deps**

```bash
mix deps.get
```

Expected: ex_aws, ex_aws_s3, sweet_xml, hackney fetched.

- [ ] **Step 3: Add Garage config to config/config.exs**

```elixir
config :ex_aws,
  access_key_id: {:system, "GARAGE_ACCESS_KEY_ID"},
  secret_access_key: {:system, "GARAGE_SECRET_ACCESS_KEY"},
  region: "garage",
  s3: [
    scheme: "http://",
    host: "localhost",
    port: 3900
  ]
```

- [ ] **Step 4: Add runtime config to config/runtime.exs**

```elixir
config :ex_aws,
  access_key_id: System.get_env("GARAGE_ACCESS_KEY_ID") || "dev-key",
  secret_access_key: System.get_env("GARAGE_SECRET_ACCESS_KEY") || "dev-secret",
  s3: [
    scheme: System.get_env("GARAGE_SCHEME") || "http://",
    host: System.get_env("GARAGE_HOST") || "localhost",
    port: String.to_integer(System.get_env("GARAGE_PORT") || "3900")
  ]
```

- [ ] **Step 5: Compile to check for errors**

```bash
mix compile
```

Expected: compiles cleanly.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(storage): add ex_aws + ex_aws_s3 deps and Garage config"
```

---

### Task 2.2: Create the Storage context

**Files:**
- Create: `lib/tore/storage.ex`

- [ ] **Step 1: Write the Storage module**

```elixir
# lib/tore/storage.ex
defmodule Tore.Storage do
  @moduledoc """
  Object storage via Garage (S3-compatible).
  Buckets: tore-recipes, tore-receipts, tore-uploads (temp, TTL-cleaned).
  Keys: <bucket>/<uuid>.<ext>
  """

  @buckets %{
    recipes: "tore-recipes",
    receipts: "tore-receipts",
    uploads: "tore-uploads"
  }

  @spec put(atom(), String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def put(bucket, key, data, content_type) do
    bucket_name = Map.fetch!(@buckets, bucket)

    case ExAws.S3.put_object(bucket_name, key, data, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get(atom(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get(bucket, key) do
    bucket_name = Map.fetch!(@buckets, bucket)

    case ExAws.S3.get_object(bucket_name, key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key) do
    bucket_name = Map.fetch!(@buckets, bucket)

    case ExAws.S3.delete_object(bucket_name, key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec url(atom(), String.t()) :: String.t()
  def url(bucket, key) do
    bucket_name = Map.fetch!(@buckets, bucket)
    host = Application.get_env(:ex_aws, :s3)[:host] || "localhost"
    port = Application.get_env(:ex_aws, :s3)[:port] || 3900
    scheme = Application.get_env(:ex_aws, :s3)[:scheme] || "http://"
    "#{scheme}#{host}:#{port}/#{bucket_name}/#{key}"
  end

  @spec generate_key(String.t()) :: String.t()
  def generate_key(ext), do: "#{Ecto.UUID.generate()}.#{ext}"

  @spec ensure_buckets() :: :ok
  def ensure_buckets do
    for {_atom, name} <- @buckets do
      case ExAws.S3.put_bucket(name, "garage") |> ExAws.request() do
        {:ok, _} -> :ok
        {:error, {:http_error, 409, _}} -> :ok
        {:error, reason} -> raise "Failed to create bucket #{name}: #{inspect(reason)}"
      end
    end
    :ok
  end
end
```

- [ ] **Step 2: Write a unit test (mocked — no live Garage needed)**

```elixir
# test/tore/storage_test.exs
defmodule Tore.StorageTest do
  use ExUnit.Case, async: true

  test "generate_key/1 produces a uuid with the given extension" do
    key = Tore.Storage.generate_key("jpg")
    assert String.ends_with?(key, ".jpg")
    assert String.length(key) > 4
  end

  test "url/2 builds correct path" do
    url = Tore.Storage.url(:recipes, "abc123.jpg")
    assert String.contains?(url, "tore-recipes")
    assert String.contains?(url, "abc123.jpg")
  end
end
```

- [ ] **Step 3: Run storage tests**

```bash
mix test test/tore/storage_test.exs
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(storage): add Storage context wrapping ex_aws_s3 for Garage"
```

---

### Task 2.3: Replace disk upload paths with Storage keys in Receipt and Recipe schemas

**Files:**
- Modify: `lib/tore/costs/receipt.ex` — `image_path` → `image_key`
- Modify: `lib/tore/recipes/recipe.ex` — `image_path` → `image_key`
- Modify: `lib/tore/handlers/costs_handler.ex`
- Modify: `lib/tore/handlers/recipe_handler.ex`

- [ ] **Step 1: Update `costs_handler.ex` to store to Garage**

In `lib/tore/handlers/costs_handler.ex`, find `parse_and_log_receipt/2`. Replace the `store_image` call (if present) with:

```elixir
def parse_and_log_receipt(image_binary, user_id) do
  key = Tore.Storage.generate_key("jpg")
  family_id = Tore.Family.get_family!().id

  with {:ok, _} <- Tore.Storage.put(:receipts, key, image_binary, "image/jpeg"),
       {:ok, %{total: total, store_name: store_name, items: items}, usage} <-
         @llm.parse_receipt_for_pantry(image_binary),
       :ok <- Tore.SpendGuard.log_usage(:parse_receipt, usage) do
    Tore.Costs.log_receipt(%{
      line_items: items,
      user_id: user_id,
      family_id: family_id,
      image_key: key,
      total_amount: total,
      store_name: store_name,
      date: Date.utc_today()
    })
  end
end
```

- [ ] **Step 2: Run full test suite**

```bash
mix test
```

Fix any compilation errors from the `image_path` → `image_key` rename.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(storage): replace disk image_path with Garage image_key on receipts and recipes"
```

---

## Phase 3 — Home Screen (Tonight + Week Strip)

### Task 3.1: Build the HomeLive view

**Files:**
- Create: `lib/tore_web/live/home_live.ex`
- Create: `lib/tore_web/live/home_live.html.heex`
- Modify: `lib/tore_web/router.ex` — make `/` point to `HomeLive`

- [ ] **Step 1: Write the HomeLive module**

```elixir
# lib/tore_web/live/home_live.ex
defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Planning.Decider, Handlers.PlanningHandler, Recipes}

  @plan_id "plan:current"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tore.PubSub, "plan")

    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    today = Date.utc_today()
    week_start = week_start(today)

    {:ok, assign(socket,
      state: state,
      today: today,
      week_start: week_start,
      tonight: tonight_slot(state, today),
      week_slots: week_slots(state, week_start),
      shuffling: false
    )}
  end

  def handle_info({:events, _events}, socket) do
    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    today = socket.assigns.today
    {:noreply, assign(socket,
      state: state,
      tonight: tonight_slot(state, today),
      week_slots: week_slots(state, socket.assigns.week_start)
    )}
  end

  def handle_event("shuffle_tonight", _params, socket) do
    {:noreply, assign(socket, shuffling: true)}
  end

  defp tonight_slot(state, today) do
    day = today |> Date.day_of_week() |> day_atom()
    slot_key = "#{day}_dinner"
    slot = Map.get(state.slots, slot_key)

    case slot do
      %{recipe_id: id} when not is_nil(id) ->
        recipe = Recipes.get!(id)
        %{slot_key: slot_key, recipe: recipe, slot: slot}
      _ ->
        nil
    end
  end

  defp week_slots(state, week_start) do
    0..6
    |> Enum.map(fn offset ->
      date = Date.add(week_start, offset)
      day = date |> Date.day_of_week() |> day_atom()
      slot_key = "#{day}_dinner"
      slot = Map.get(state.slots, slot_key)
      recipe = slot && slot.recipe_id && Recipes.get!(slot.recipe_id)
      %{date: date, day: day, slot_key: slot_key, slot: slot, recipe: recipe}
    end)
  end

  defp week_start(today) do
    days_since_monday = Date.day_of_week(today) - 1
    Date.add(today, -days_since_monday)
  end

  defp day_atom(1), do: "mon"
  defp day_atom(2), do: "tue"
  defp day_atom(3), do: "wed"
  defp day_atom(4), do: "thu"
  defp day_atom(5), do: "fri"
  defp day_atom(6), do: "sat"
  defp day_atom(7), do: "sun"
end
```

- [ ] **Step 2: Write the template**

```heex
<%!-- lib/tore_web/live/home_live.html.heex --%>
<Layouts.app flash={@flash} current_path="/">
  <.page max_width={:sm}>
    <%!-- Tonight hero — photo alongside text, not behind it --%>
    <div class="rounded-2xl overflow-hidden mb-4 bg-[color:var(--surface-raised)]">
      <%= if @tonight do %>
        <div class="flex gap-4 p-4">
          <%= if @tonight.recipe.image_key do %>
            <img
              src={Tore.Storage.url(:recipes, @tonight.recipe.image_key)}
              class="w-28 h-28 object-cover rounded-xl flex-shrink-0"
            />
          <% end %>
          <div class="flex flex-col justify-between flex-1 min-w-0">
            <div>
              <p class="text-[color:var(--muted)] text-xs mb-1">{gettext("Tonight")}</p>
              <h1 class="text-[var(--text)] text-xl font-semibold leading-tight">
                {@tonight.recipe.title}
              </h1>
            </div>
            <div class="flex gap-2 mt-3">
              <.link navigate={"/recipes/#{@tonight.recipe.id}"}
                class="flex-1 bg-[color:var(--accent)] text-white text-sm font-medium py-2.5 rounded-xl text-center">
                {gettext("Start cooking")}
              </.link>
              <button
                phx-click="shuffle_tonight"
                class="bg-[color:var(--surface)] text-[var(--text)] text-sm font-medium px-3 py-2.5 rounded-xl border border-[color:var(--hairline)]">
                {gettext("Something else")}
              </button>
            </div>
          </div>
        </div>
      <% else %>
        <div class="p-6 flex flex-col items-center justify-center min-h-[160px]">
          <p class="text-[color:var(--muted)] text-center">{gettext("No dinner planned for tonight.")}</p>
          <.link navigate="/planner" class="mt-4 text-[color:var(--accent)] text-sm font-medium">
            {gettext("Open planner")}
          </.link>
        </div>
      <% end %>
    </div>

    <%!-- Week strip --%>
    <div class="flex gap-2 overflow-x-auto pb-2 snap-x">
      <%= for day <- @week_slots do %>
        <.link
          navigate="/planner"
          class={[
            "snap-start shrink-0 w-20 rounded-xl overflow-hidden border transition-colors",
            day.date == @today && "border-[color:var(--accent)]",
            day.date != @today && "border-[color:var(--hairline)]"
          ]}
        >
          <div class="bg-[color:var(--surface-raised)] h-20 relative">
            <%= if day.recipe && day.recipe.image_key do %>
              <img
                src={Tore.Storage.url(:recipes, day.recipe.image_key)}
                class="w-full h-full object-cover"
              />
            <% end %>
          </div>
          <div class="p-1.5 bg-[color:var(--surface)]">
            <p class={[
              "text-xs font-medium truncate",
              day.date == @today && "text-[color:var(--accent)]",
              day.date != @today && "text-[color:var(--muted)]"
            ]}>
              {day.day |> String.capitalize() |> String.slice(0, 3)}
            </p>
            <p class="text-xs text-[color:var(--text)] truncate leading-tight mt-0.5">
              {if day.recipe, do: day.recipe.title, else: "–"}
            </p>
          </div>
        </.link>
      <% end %>
    </div>
  </.page>
</Layouts.app>
```

- [ ] **Step 3: Update router — make `/` point to HomeLive**

In `lib/tore_web/router.ex`, change:

```elixir
live "/", PlannerLive
```

to:

```elixir
live "/", HomeLive
live "/planner", PlannerLive
```

- [ ] **Step 4: Run the app and verify the home screen loads**

```bash
mix phx.server
```

Open http://localhost:4000. Expected: home screen renders with tonight's meal (or "No dinner planned") and week strip.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(home): tonight + week strip home screen"
```

---

## Phase 4 — FAB + Chat Assistant (Text Commands)

### Task 4.1: Create the AI chat context and message structs

**Files:**
- Create: `lib/tore/chat/message.ex`
- Create: `lib/tore/chat/action.ex`

- [ ] **Step 1: Write the Message struct**

```elixir
# lib/tore/chat/message.ex
defmodule Tore.Chat.Message do
  @type role :: :user | :assistant
  @type t :: %__MODULE__{
    id: String.t(),
    role: role(),
    text: String.t(),
    action: Tore.Chat.Action.t() | nil,
    inserted_at: DateTime.t()
  }

  defstruct [:id, :role, :text, :action, inserted_at: nil]

  def new(role, text, opts \\ []) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      role: role,
      text: text,
      action: Keyword.get(opts, :action),
      inserted_at: DateTime.utc_now()
    }
  end
end
```

- [ ] **Step 2: Write the Action struct**

Actions are risk-tiered:
- **Tier 1** (add pantry/grocery item): act immediately, toast + undo chip.
- **Tier 2** (swap/skip meal): act immediately, toast + undo chip. Compensating event handles undo.
- **Tier 3** (reshuffle week, clear pantry): show a confirm chip in chat before acting.

```elixir
# lib/tore/chat/action.ex
defmodule Tore.Chat.Action do
  @type action_type ::
    :add_pantry_item | :remove_pantry_item |
    :add_grocery_item | :remove_grocery_item |
    :assign_recipe | :swap_recipe | :skip_meal |
    :reshuffle_week | :review_upload

  @type tier :: 1 | 2 | 3

  @type t :: %__MODULE__{
    type: action_type(),
    params: map(),
    tier: tier(),
    correlation_id: String.t(),
    undo_operation_id: String.t() | nil
  }

  defstruct [:type, :params, :correlation_id, :undo_operation_id, tier: 1]

  @tier_map %{
    add_pantry_item: 1,
    remove_pantry_item: 1,
    add_grocery_item: 1,
    remove_grocery_item: 1,
    assign_recipe: 2,
    swap_recipe: 2,
    skip_meal: 2,
    reshuffle_week: 3,
    review_upload: 1
  }

  def new(type, params, opts \\ []) do
    %__MODULE__{
      type: type,
      params: params,
      tier: Map.get(@tier_map, type, 1),
      correlation_id: Keyword.get(opts, :correlation_id, Ecto.UUID.generate()),
      undo_operation_id: Keyword.get(opts, :undo_operation_id)
    }
  end
end
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(chat): add Message and Action structs"
```

---

### Task 4.2: Add `parse_assistant_command/1` to LLM behaviour and OpenRouter adapter

**Files:**
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/adapters/open_router.ex`
- Create: `priv/llm/prompts/parse_assistant_command.eex`

- [ ] **Step 1: Add callback to LLM behaviour**

In `lib/tore/llm.ex`, add:

```elixir
@callback parse_assistant_command(input :: String.t(), context :: map()) ::
  {:ok, map()} | {:error, term()}
```

- [ ] **Step 2: Write the prompt template**

```eex
<%# priv/llm/prompts/parse_assistant_command.eex %>
You are the AI assistant for Tore, a meal planning app. The user has typed a command.
Parse it into a structured action. Return JSON only.

Current context:
- Today: <%= @today %>
- Current week plan: <%= @plan_summary %>
- Pantry items: <%= @pantry_summary %>

Supported actions:
- add_pantry_item: { "action": "add_pantry_item", "name": "...", "quantity": 1.0, "unit": "kg", "expires_at": "2026-06-02" }
- remove_pantry_item: { "action": "remove_pantry_item", "name": "..." }
- add_grocery_item: { "action": "add_grocery_item", "name": "...", "quantity": 1, "unit": "st" }
- remove_grocery_item: { "action": "remove_grocery_item", "name": "..." }
- assign_recipe: { "action": "assign_recipe", "slot_key": "wed_dinner", "recipe_title": "..." }
- skip_meal: { "action": "skip_meal", "slot_key": "thu_dinner" }
- reshuffle_week: { "action": "reshuffle_week", "constraint": "I want fried rice on Wednesday" }
- unknown: { "action": "unknown", "reply": "I couldn't understand that. Try: add chicken to pantry, skip Thursday dinner, etc." }

User input: <%= @input %>
```

- [ ] **Step 3: Add to OpenRouter adapter**

In `lib/tore/adapters/open_router.ex`, add:

```elixir
@impl Tore.LLM
def parse_assistant_command(input, context) do
  system = "You are the AI assistant for Tore meal planner. Return only valid JSON."
  user = EEx.eval_file(
    Application.app_dir(:tore, "priv/llm/prompts/parse_assistant_command.eex"),
    [assigns: Map.put(context, :input, input)]
  )

  case chat(system, user) do
    {:ok, %{"action" => _} = result, usage} -> {:ok, result, usage}
    {:ok, _, _} -> {:error, :invalid_response}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 4: Add stub to test mock**

In `test/support/mocks.ex` (or wherever Mox mocks are defined), ensure `parse_assistant_command/2` is included in the mock. Check:

```bash
grep -r "Mox.defmock" test/
```

Add `:parse_assistant_command` to the mock callbacks list if not already there.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(chat): add parse_assistant_command LLM callback and prompt"
```

---

### Task 4.3: Create the ChatHandler

**Files:**
- Create: `lib/tore/handlers/chat_handler.ex`

- [ ] **Step 1: Write the ChatHandler**

```elixir
# lib/tore/handlers/chat_handler.ex
defmodule Tore.Handlers.ChatHandler do
  alias Tore.{
    Family, Pantry, Handlers.PlanningHandler,
    Handlers.GroceriesHandler, Recipes, Chat.Action
  }
  alias Phoenix.PubSub

  @llm Application.compile_env(:tore, :llm_client)
  @plan_id "plan:current"
  @grocery_id "grocery:current"

  @spec handle_text(String.t(), map()) ::
    {:ok, String.t(), Action.t() | nil} | {:error, term()}
  def handle_text(input, context) do
    with {:ok, parsed, _usage} <- @llm.parse_assistant_command(input, context) do
      dispatch(parsed)
    end
  end

  defp dispatch(%{"action" => "add_pantry_item"} = cmd) do
    family_id = Family.get_family!().id
    attrs = %{
      name: cmd["name"],
      quantity: cmd["quantity"],
      unit: cmd["unit"],
      expires_at: parse_date(cmd["expires_at"]),
      family_id: family_id,
      added_at: DateTime.utc_now()
    }

    case Pantry.add_item(attrs) do
      {:ok, item} ->
        reply = "Done — added #{item.name}" <>
          (if item.expires_at, do: ", expires #{item.expires_at}", else: "") <>
          " to your pantry."
        action = Action.new(:add_pantry_item, %{item_id: item.id})
        {:ok, reply, action}
      {:error, _} -> {:error, :failed}
    end
  end

  defp dispatch(%{"action" => "skip_meal"} = cmd) do
    slot_key = cmd["slot_key"]
    case PlanningHandler.skip_meal(@plan_id, slot_key) do
      {:ok, _events} ->
        {:ok, "Done — skipped #{slot_key}.", Action.new(:skip_meal, %{slot_key: slot_key})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(%{"action" => "assign_recipe"} = cmd) do
    recipe = Recipes.find_by_title(cmd["recipe_title"])
    slot_key = cmd["slot_key"]

    case recipe do
      nil ->
        {:ok, "I couldn't find a recipe called \"#{cmd["recipe_title"]}\" in your catalog.", nil}
      r ->
        case PlanningHandler.assign_recipe(@plan_id, slot_key, r.id, r.base_servings || 4) do
          {:ok, _} ->
            {:ok, "Done — assigned #{r.title} to #{slot_key}.",
             Action.new(:assign_recipe, %{slot_key: slot_key, recipe_id: r.id})}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp dispatch(%{"action" => "add_grocery_item"} = cmd) do
    case GroceriesHandler.add_item(@grocery_id, cmd["name"], cmd["quantity"], cmd["unit"]) do
      {:ok, _} ->
        {:ok, "Done — added #{cmd["name"]} to your grocery list.",
         Action.new(:add_grocery_item, %{name: cmd["name"]})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(%{"action" => "unknown", "reply" => reply}) do
    {:ok, reply, nil}
  end

  defp dispatch(_), do: {:ok, "I'm not sure how to help with that yet.", nil}

  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end
end
```

- [ ] **Step 2: Add `find_by_title/1` to `Tore.Recipes`**

In `lib/tore/recipes.ex`, add:

```elixir
@spec find_by_title(String.t()) :: Recipe.t() | nil
def find_by_title(title) do
  family_id = Tore.Family.get_family!().id
  Repo.one(from r in Recipe,
    where: r.family_id == ^family_id and ilike(r.title, ^title),
    limit: 1)
end
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(chat): add ChatHandler dispatching LLM commands to existing handlers"
```

---

### Task 4.4: Build the FAB + ChatLive component

**Files:**
- Create: `lib/tore_web/live/chat_live.ex`
- Modify: `lib/tore_web/components/layouts.ex` — embed FAB in app layout
- Modify: `lib/tore_web/router.ex` — add chat live route

- [ ] **Step 1: Write ChatLive**

```elixir
# lib/tore_web/live/chat_live.ex
defmodule ToreWeb.ChatLive do
  use ToreWeb, :live_view

  alias Tore.{Chat.Message, Handlers.ChatHandler, Family}

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      messages: [],
      input: "",
      loading: false
    )}
  end

  def handle_event("submit", %{"input" => ""}, socket), do: {:noreply, socket}

  def handle_event("submit", %{"input" => input}, socket) do
    user_msg = Message.new(:user, input)
    messages = socket.assigns.messages ++ [user_msg]

    socket = assign(socket, messages: messages, input: "", loading: true)
    send(self(), {:dispatch_command, input})
    {:noreply, socket}
  end

  def handle_info({:dispatch_command, input}, socket) do
    context = build_context()

    {reply, action} =
      case ChatHandler.handle_text(input, context) do
        {:ok, reply, action} -> {reply, action}
        {:error, _} -> {"Something went wrong — please try again.", nil}
      end

    assistant_msg = Message.new(:assistant, reply, action: action)
    messages = socket.assigns.messages ++ [assistant_msg]
    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns[:return_to] || "/")}
  end

  defp build_context do
    family = Family.get_family!()
    %{
      today: Date.utc_today(),
      plan_summary: "",
      pantry_summary: ""
    }
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex flex-col bg-[color:var(--bg)]">
      <header class="flex items-center justify-between px-4 py-3 border-b border-[color:var(--hairline)]">
        <h2 class="font-semibold text-[var(--text)]">{gettext("Assistant")}</h2>
        <button phx-click="close" class="p-2 text-[color:var(--muted)]">
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <div class="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-3">
        <%= for msg <- @messages do %>
          <div class={[
            "max-w-[85%] rounded-2xl px-4 py-3",
            msg.role == :user && "ml-auto bg-[color:var(--accent)] text-white",
            msg.role == :assistant && "bg-[color:var(--surface-raised)] text-[var(--text)]"
          ]}>
            <p class="text-sm leading-relaxed">{msg.text}</p>
          </div>
        <% end %>

        <%= if @loading do %>
          <div class="bg-[color:var(--surface-raised)] rounded-2xl px-4 py-3 max-w-[85%]">
            <p class="text-sm text-[color:var(--muted)]">{gettext("Thinking…")}</p>
          </div>
        <% end %>
      </div>

      <div class="px-4 py-3 border-t border-[color:var(--hairline)]">
        <form phx-submit="submit" class="flex gap-2">
          <input
            type="text"
            name="input"
            value={@input}
            placeholder={gettext("Add chicken to pantry, skip Thursday…")}
            autocomplete="off"
            class="flex-1 rounded-xl border border-[color:var(--hairline)] bg-[color:var(--surface)] px-4 py-2.5 text-sm text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
          />
          <button type="submit"
            class="bg-[color:var(--accent)] text-white rounded-xl px-4 py-2.5 text-sm font-medium">
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
        </form>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add the FAB to the app layout**

In `lib/tore_web/components/layouts.ex`, find the `app/1` component. Add the FAB before the closing `</div>`:

```heex
<%!-- FAB --%>
<.link navigate="/chat"
  class="fixed bottom-20 right-4 z-40 size-14 rounded-full bg-[color:var(--accent)] text-white shadow-lg flex items-center justify-center">
  <.icon name="hero-sparkles" class="size-6" />
</.link>
```

- [ ] **Step 3: Add chat route to router**

In `lib/tore_web/router.ex`, inside the authenticated live_session, add:

```elixir
live "/chat", ChatLive
```

- [ ] **Step 4: Start the server and test the chat**

```bash
mix phx.server
```

Navigate to http://localhost:4000. Tap the FAB (sparkles icon). Type "add 1 kg chicken expiring Monday to pantry". Verify:
- A user message appears
- "Thinking…" appears briefly
- An assistant message appears confirming the action
- The pantry actually has the item (check http://localhost:4000/pantry)

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(chat): FAB + ChatLive with text command dispatch"
```

---

## Phase 5 — Photo Classification Pipeline in Chat

### Task 5.1: Add `classify_images/1` to LLM behaviour

**Files:**
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/adapters/open_router.ex`

- [ ] **Step 1: Add classify_images callback**

In `lib/tore/llm.ex`, add:

```elixir
@type image_class :: :receipt | :recipe | :pantry_items | :fridge
@callback classify_images(images :: [binary()]) ::
  {:ok, [%{index: integer(), class: image_class(), confidence: float()}]} | {:error, term()}
```

- [ ] **Step 2: Implement in OpenRouter adapter**

In `lib/tore/adapters/open_router.ex`, add:

```elixir
@impl Tore.LLM
def classify_images(images) do
  system = """
  You are a photo classifier for a meal planning app.
  For each image, classify it as one of: receipt, recipe, pantry_items, fridge.
  Return JSON: {"classifications": [{"index": 0, "class": "receipt", "confidence": 0.95}, ...]}
  Confidence is a float 0.0–1.0. If unsure, set confidence below 0.6.
  """

  image_content =
    images
    |> Enum.with_index()
    |> Enum.map(fn {bin, idx} ->
      b64 = Base.encode64(bin)
      [
        %{type: "text", text: "Image #{idx}:"},
        %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,#{b64}"}}
      ]
    end)
    |> List.flatten()

  body = %{
    model: vision_model(),
    messages: [
      %{role: "system", content: system},
      %{role: "user", content: image_content}
    ]
  }

  case Req.post(@api_url, json: body, headers: auth_headers()) do
    {:ok, %{body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
      case Jason.decode(content) do
        {:ok, %{"classifications" => classes}} ->
          {:ok, Enum.map(classes, fn c ->
          %{index: c["index"], class: String.to_atom(c["class"]), confidence: c["confidence"] || 1.0}
        end)}
        _ -> {:error, :parse_error}
      end
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(chat): add classify_images LLM callback for photo routing"
```

---

### Task 5.2: Create the PhotoPipeline module

**Files:**
- Create: `lib/tore/chat/photo_pipeline.ex`

- [ ] **Step 1: Write the PhotoPipeline**

```elixir
# lib/tore/chat/photo_pipeline.ex
defmodule Tore.Chat.PhotoPipeline do
  @moduledoc """
  Classifies uploaded photos, groups by class, routes each group
  to the correct structured-output pipeline.

  Returns a list of results, one per class group.
  """

  alias Tore.{Storage, Family}

  @llm Application.compile_env(:tore, :llm_client)

  @type result :: %{
    class: atom(),
    status: :ok | :error,
    data: map() | nil,
    review_required: boolean()
  }

  @low_confidence_threshold 0.6

  @spec process([binary()]) :: {:ok, [result()]} | {:error, term()}
  def process([]), do: {:ok, []}

  def process(images) when is_list(images) do
    with {:ok, classifications} <- @llm.classify_images(images) do
      {high, low} = Enum.split_with(classifications, fn c -> c.confidence >= @low_confidence_threshold end)
      groups = group_by_class(images, high)
      pipeline_results = Enum.map(groups, fn {class, imgs} -> run_pipeline(class, imgs) end)

      # Low-confidence images return a disambiguation result instead of routing to a pipeline
      disambiguation_results = Enum.map(low, fn c ->
        %{class: :unknown, status: :ambiguous, data: %{index: c.index, top_class: c.class, confidence: c.confidence}, review_required: false}
      end)

      {:ok, pipeline_results ++ disambiguation_results}
    end
  end

  defp group_by_class(images, classifications) do
    classifications
    |> Enum.group_by(& &1.class, fn c -> Enum.at(images, c.index) end)
  end

  defp run_pipeline(:receipt, images) do
    image = List.first(images)
    case @llm.parse_receipt_for_pantry(image) do
      {:ok, %{total: total, store_name: store, items: items}, _usage} ->
        %{class: :receipt, status: :ok, data: %{total: total, store_name: store, items: items}, review_required: true}
      {:error, reason} ->
        %{class: :receipt, status: :error, data: nil, review_required: false}
    end
  end

  defp run_pipeline(:recipe, images) do
    locale = Family.locale()
    case @llm.parse_recipe_images(images, locale) do
      {:ok, recipe_attrs} ->
        %{class: :recipe, status: :ok, data: recipe_attrs, review_required: true}
      {:error, _reason} ->
        %{class: :recipe, status: :error, data: nil, review_required: false}
    end
  end

  defp run_pipeline(:pantry_items, images) do
    image = List.first(images)
    case @llm.parse_pantry_image(image) do
      {:ok, items, _usage} ->
        %{class: :pantry_items, status: :ok, data: %{items: items}, review_required: true}
      {:error, _} ->
        %{class: :pantry_items, status: :error, data: nil, review_required: false}
    end
  end

  defp run_pipeline(:fridge, images) do
    image = List.first(images)
    case @llm.parse_pantry_image(image) do
      {:ok, items, _usage} ->
        %{class: :fridge, status: :ok, data: %{items: items}, review_required: false}
      {:error, _} ->
        %{class: :fridge, status: :error, data: nil, review_required: false}
    end
  end
end
```

- [ ] **Step 2: Write a test**

```elixir
# test/tore/chat/photo_pipeline_test.exs
defmodule Tore.Chat.PhotoPipelineTest do
  use Tore.DataCase, async: true

  import Mox
  alias Tore.Chat.PhotoPipeline

  setup :verify_on_exit!

  test "process/1 with empty list returns empty results" do
    assert {:ok, []} = PhotoPipeline.process([])
  end

  test "process/1 classifies and routes receipt image" do
    Tore.LLMMock
    |> expect(:classify_images, fn [_img] ->
      {:ok, [%{index: 0, class: :receipt}]}
    end)
    |> expect(:parse_receipt_for_pantry, fn _img ->
      {:ok, %{total: Decimal.new("123.50"), store_name: "ICA", items: [%{name: "Chicken", quantity: 1.0, unit: "kg"}]}, %{}}
    end)

    fake_image = <<1, 2, 3>>
    assert {:ok, [result]} = PhotoPipeline.process([fake_image])
    assert result.class == :receipt
    assert result.review_required == true
    assert result.data.store_name == "ICA"
  end
end
```

- [ ] **Step 3: Run the test**

```bash
mix test test/tore/chat/photo_pipeline_test.exs
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(chat): add PhotoPipeline — classify, group, route photos to LLM pipelines"
```

---

### Task 5.3: Add photo upload to ChatLive + polymorphic review screen

**Files:**
- Modify: `lib/tore_web/live/chat_live.ex`
- Create: `lib/tore_web/live/review_live.ex`
- Modify: `lib/tore_web/router.ex`

- [ ] **Step 1: Add upload support to ChatLive**

In `lib/tore_web/live/chat_live.ex`, update `mount/3` to allow uploads:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(messages: [], input: "", loading: false)
   |> allow_upload(:photos,
     accept: ~w(.jpg .jpeg .png .webp),
     max_entries: 10,
     max_file_size: 20_000_000
   )}
end
```

Add a photo button to the form in `render/1`:

```heex
<form phx-submit="submit" phx-change="validate" class="flex flex-col gap-2">
  <%= if length(@uploads.photos.entries) > 0 do %>
    <div class="flex flex-wrap gap-1 px-1">
      <%= for entry <- @uploads.photos.entries do %>
        <div class="relative">
          <.live_img_preview entry={entry} class="w-14 h-14 object-cover rounded-lg" />
          <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}
            class="absolute -top-1 -right-1 bg-red-500 text-white rounded-full size-4 flex items-center justify-center text-xs">
            ×
          </button>
        </div>
      <% end %>
    </div>
  <% end %>
  <div class="flex gap-2">
    <label class="cursor-pointer p-2.5 rounded-xl border border-[color:var(--hairline)] text-[color:var(--muted)]">
      <.icon name="hero-camera" class="size-5" />
      <.live_file_input upload={@uploads.photos} class="sr-only" />
    </label>
    <input type="text" name="input" value={@input}
      placeholder={gettext("Add chicken, skip Thursday…")}
      autocomplete="off"
      class="flex-1 rounded-xl border border-[color:var(--hairline)] bg-[color:var(--surface)] px-4 py-2.5 text-sm text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]" />
    <button type="submit"
      class="bg-[color:var(--accent)] text-white rounded-xl px-4 py-2.5 text-sm font-medium">
      <.icon name="hero-arrow-up" class="size-4" />
    </button>
  </div>
</form>
```

Add event handlers:

```elixir
def handle_event("validate", _params, socket), do: {:noreply, socket}

def handle_event("cancel_upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :photos, ref)}
end

def handle_event("submit", %{"input" => input}, socket) do
  photo_binaries =
    consume_uploaded_entries(socket, :photos, fn %{path: path}, _entry ->
      {:ok, File.read!(path)}
    end)

  user_text = if input == "" and photo_binaries != [], do: "(photo)", else: input
  user_msg = Message.new(:user, user_text)
  messages = socket.assigns.messages ++ [user_msg]
  socket = assign(socket, messages: messages, input: "", loading: true)

  send(self(), {:dispatch, input, photo_binaries})
  {:noreply, socket}
end

def handle_info({:dispatch, input, []}, socket) do
  # text-only path (existing)
  context = build_context()
  {reply, action} =
    case Tore.Handlers.ChatHandler.handle_text(input, context) do
      {:ok, r, a} -> {r, a}
      {:error, _} -> {"Something went wrong — please try again.", nil}
    end
  msg = Message.new(:assistant, reply, action: action)
  {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], loading: false)}
end

def handle_info({:dispatch, _input, photos}, socket) do
  # photo path
  case Tore.Chat.PhotoPipeline.process(photos) do
    {:ok, results} ->
      msgs = Enum.map(results, fn result ->
        {text, action} = result_to_message(result)
        Message.new(:assistant, text, action: action)
      end)
      {:noreply, assign(socket, messages: socket.assigns.messages ++ msgs, loading: false)}
    {:error, _} ->
      msg = Message.new(:assistant, "I couldn't process those photos — please try again.")
      {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], loading: false)}
  end
end

defp result_to_message(%{class: :receipt, status: :ok, data: data}) do
  store = data.store_name || "the store"
  items = length(data.items)
  text = "Parsed your receipt from #{store} — #{items} items found."
  action = %Tore.Chat.Action{type: :review_upload, params: %{class: :receipt, data: data}}
  {text, action}
end

defp result_to_message(%{class: :recipe, status: :ok, data: data}) do
  text = "Found a recipe: #{data["title"] || "untitled"}."
  action = %Tore.Chat.Action{type: :review_upload, params: %{class: :recipe, data: data}}
  {text, action}
end

defp result_to_message(%{class: :pantry_items, status: :ok, data: %{items: items}}) do
  text = "Found #{length(items)} pantry items in the photo."
  action = %Tore.Chat.Action{type: :review_upload, params: %{class: :pantry_items, data: %{items: items}}}
  {text, action}
end

defp result_to_message(%{class: :fridge, status: :ok, data: %{items: items}}) do
  titles = items |> Enum.take(3) |> Enum.map(& &1["name"]) |> Enum.join(", ")
  text = "I can see: #{titles}. Want a recipe suggestion?"
  {text, nil}
end

defp result_to_message(%{class: :unknown, status: :ambiguous, data: %{top_class: top}}) do
  class_label = case top do
    :receipt -> "a receipt"
    :recipe -> "a recipe"
    :pantry_items -> "pantry items"
    :fridge -> "fridge contents"
    _ -> "something"
  end
  {"I'm not sure what this photo is — looks like #{class_label}? Let me know what it is and I'll try again.", nil}
end

defp result_to_message(%{status: :error, class: class}) do
  {"Couldn't parse the #{class} photo — please try again.", nil}
end
```

Add a "Review" button rendering in the message list (in `render/1`), after `msg.text`:

```heex
<%= if msg.action && msg.action.type == :review_upload do %>
  <.link navigate={"/review/#{msg.action.params.class}"}
    class="mt-2 inline-block text-sm font-medium text-[color:var(--accent)] underline">
    {gettext("Review")}
  </.link>
<% end %>
```

Note: for the Review link to pass data, you'll need to store the parsed data in a temporary session or pass it via the process registry. For now, store in socket assigns keyed by a UUID and pass that UUID in the link. This is covered in Task 5.4.

- [ ] **Step 2: Commit**

```bash
jj describe -m "feat(chat): photo upload in chat, classification and review card"
```

---

### Task 5.4: Build the polymorphic ReviewLive

**Files:**
- Create: `lib/tore_web/live/review_live.ex`
- Modify: `lib/tore_web/router.ex`

- [ ] **Step 1: Write ReviewLive**

```elixir
# lib/tore_web/live/review_live.ex
defmodule ToreWeb.ReviewLive do
  use ToreWeb, :live_view

  alias Tore.{Family, Pantry, Costs, Recipes}

  def mount(%{"class" => class, "id" => id}, _session, socket) do
    data = Tore.ReviewStore.get(id)
    {:ok, assign(socket, class: String.to_atom(class), data: data, saving: false)}
  end

  def handle_event("confirm", _params, socket) do
    {:noreply, assign(socket, saving: true)}
    send(self(), :save)
    {:noreply, socket}
  end

  def handle_info(:save, %{assigns: %{class: :receipt, data: data}} = socket) do
    family_id = Family.get_family!().id
    Costs.log_receipt(%{
      store_name: data.store_name,
      total_amount: data.total,
      line_items: data.items,
      family_id: family_id,
      date: Date.utc_today()
    })
    {:noreply, push_navigate(socket, to: "/chat")}
  end

  def handle_info(:save, %{assigns: %{class: :recipe, data: data}} = socket) do
    family_id = Family.get_family!().id
    Tore.Handlers.RecipeHandler.save_from_attrs(Map.put(data, "family_id", family_id))
    {:noreply, push_navigate(socket, to: "/recipes")}
  end

  def handle_info(:save, %{assigns: %{class: :pantry_items, data: %{items: items}}} = socket) do
    family_id = Family.get_family!().id
    Enum.each(items, fn item ->
      Pantry.add_item(%{
        name: item["name"],
        quantity: item["quantity"],
        unit: item["unit"],
        family_id: family_id,
        added_at: DateTime.utc_now()
      })
    end)
    {:noreply, push_navigate(socket, to: "/pantry")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/chat">
      <.page max_width={:sm}>
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-xl font-semibold text-[var(--text)]">
            {review_title(@class)}
          </h1>
          <.link navigate="/chat" class="text-[color:var(--muted)]">
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>

        <p class="text-xs text-[color:var(--muted)] mb-4 italic">
          {gettext("Nothing saved yet — review and confirm to save.")}
        </p>

        <%= render_content(assigns) %>

        <div class="mt-6 flex gap-3">
          <.link navigate="/chat"
            class="flex-1 text-center py-3 rounded-xl border border-[color:var(--hairline)] text-[color:var(--muted)] text-sm font-medium">
            {gettext("Dismiss")}
          </.link>
          <button phx-click="confirm"
            class="flex-1 py-3 rounded-xl bg-[color:var(--accent)] text-white text-sm font-medium">
            {gettext("Save")}
          </button>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp review_title(:receipt), do: gettext("Receipt")
  defp review_title(:recipe), do: gettext("Recipe")
  defp review_title(:pantry_items), do: gettext("Pantry items")
  defp review_title(_), do: gettext("Review")

  defp render_content(%{class: :receipt, data: data} = assigns) do
    ~H"""
    <div class="space-y-2">
      <p class="text-sm text-[color:var(--muted)]">{@data.store_name} · {@data.total}</p>
      <div :for={item <- @data.items} class="flex justify-between text-sm py-1 border-b border-[color:var(--hairline)]">
        <span>{item["name"]}</span>
        <span class="text-[color:var(--muted)]">{item["total_price"]}</span>
      </div>
    </div>
    """
  end

  defp render_content(%{class: :recipe, data: data} = assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="font-semibold text-lg">{@data["title"]}</h2>
      <div :for={ing <- (@data["ingredients"] || [])} class="text-sm text-[color:var(--muted)]">
        {ing["quantity"]} {ing["unit"]} {ing["name"]}
      </div>
    </div>
    """
  end

  defp render_content(%{class: :pantry_items, data: %{items: items}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <div :for={item <- @data.items} class="flex justify-between text-sm py-1 border-b border-[color:var(--hairline)]">
        <span>{item["name"]}</span>
        <span class="text-[color:var(--muted)]">{item["quantity"]} {item["unit"]}</span>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Create a simple ReviewStore (ETS-backed temp store)**

```elixir
# lib/tore/review_store.ex
defmodule Tore.ReviewStore do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def put(data) do
    id = Ecto.UUID.generate()
    GenServer.call(__MODULE__, {:put, id, data})
    id
  end

  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  def init(state), do: {:ok, state}

  def handle_call({:put, id, data}, _from, state) do
    {:reply, id, Map.put(state, id, data)}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state, id), state}
  end
end
```

- [ ] **Step 3: Add ReviewStore to application supervision tree**

In `lib/tore/application.ex`, add to the children list:

```elixir
Tore.ReviewStore,
```

- [ ] **Step 4: Update ChatLive to store review data and pass ID in link**

In `result_to_message/1` in `chat_live.ex`, when creating a `review_upload` action, store data in ReviewStore:

```elixir
defp result_to_message(%{class: :receipt, status: :ok, data: data}) do
  store = data.store_name || "the store"
  items = length(data.items)
  review_id = Tore.ReviewStore.put(data)
  text = "Parsed your receipt from #{store} — #{items} items found."
  action = %Tore.Chat.Action{type: :review_upload, params: %{class: :receipt, review_id: review_id}}
  {text, action}
end
```

Update the Review link in `render/1`:

```heex
<.link navigate={"/review/#{msg.action.params.class}/#{msg.action.params.review_id}"}
  class="mt-2 inline-block text-sm font-medium text-[color:var(--accent)] underline">
  {gettext("Review")}
</.link>
```

- [ ] **Step 5: Add review route to router**

```elixir
live "/review/:class/:id", ReviewLive
```

- [ ] **Step 6: Run the app and test a full photo flow**

```bash
mix phx.server
```

1. Open http://localhost:4000
2. Tap FAB
3. Attach a receipt photo
4. Submit
5. Verify classification message appears with "Review" link
6. Tap Review
7. Verify receipt line items are shown
8. Tap Confirm
9. Verify costs are saved

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(chat): polymorphic review screen for photos, ReviewStore for temp data"
```

---

## Phase 6 — Kiosk Layout

### Task 6.1: Add a kiosk-role layout variant

**Files:**
- Modify: `lib/tore_web/components/layouts.ex`
- Modify: `lib/tore_web/router.ex`
- Create: `lib/tore_web/live/kiosk_home_live.ex`

- [ ] **Step 1: Create KioskHomeLive**

```elixir
# lib/tore_web/live/kiosk_home_live.ex
defmodule ToreWeb.KioskHomeLive do
  use ToreWeb, :live_view

  alias Tore.{Handlers.PlanningHandler, Recipes}

  @plan_id "plan:current"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tore.PubSub, "plan")
    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    today = Date.utc_today()

    {:ok, assign(socket,
      state: state,
      today: today,
      tonight: tonight_slot(state, today),
      upcoming: upcoming_slots(state, today)
    )}
  end

  def handle_info({:events, _events}, socket) do
    {:ok, state} = PlanningHandler.load_plan(@plan_id)
    today = socket.assigns.today
    {:noreply, assign(socket,
      state: state,
      tonight: tonight_slot(state, today),
      upcoming: upcoming_slots(state, today)
    )}
  end

  def handle_event("shuffle_tonight", _params, socket) do
    slot_key = tonight_slot_key(socket.assigns.today)
    {:ok, suggestions} = PlanningHandler.suggest_recipes_for_slot(@plan_id, slot_key, limit: 1)
    case suggestions do
      [%{recipe: r} | _] ->
        PlanningHandler.assign_recipe(@plan_id, slot_key, r.id, r.base_servings || 4)
        {:noreply, socket}
      [] -> {:noreply, socket}
    end
  end

  def handle_event("mark_cooked", _params, socket) do
    # Mark tonight's slot as completed — future: deplete pantry
    {:noreply, socket}
    end
  end

  defp tonight_slot(state, today) do
    slot_key = tonight_slot_key(today)
    slot = Map.get(state.slots, slot_key)
    case slot do
      %{recipe_id: id} when not is_nil(id) -> %{recipe: Recipes.get!(id), slot_key: slot_key}
      _ -> nil
    end
  end

  defp upcoming_slots(state, today) do
    1..4
    |> Enum.map(fn offset ->
      date = Date.add(today, offset)
      day = date |> Date.day_of_week() |> day_atom()
      slot_key = "#{day}_dinner"
      slot = Map.get(state.slots, slot_key)
      recipe = slot && slot.recipe_id && Recipes.get!(slot.recipe_id)
      %{date: date, day: day, recipe: recipe}
    end)
  end

  defp tonight_slot_key(today) do
    day = today |> Date.day_of_week() |> day_atom()
    "#{day}_dinner"
  end

  defp day_atom(1), do: "mon"
  defp day_atom(2), do: "tue"
  defp day_atom(3), do: "wed"
  defp day_atom(4), do: "thu"
  defp day_atom(5), do: "fri"
  defp day_atom(6), do: "sat"
  defp day_atom(7), do: "sun"

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[color:var(--bg)] flex flex-col">
      <%!-- Tonight hero (fills ~60% of screen) --%>
      <div class="relative flex-1 min-h-[60vh]">
        <%= if @tonight do %>
          <%= if @tonight.recipe.image_key do %>
            <img
              src={Tore.Storage.url(:recipes, @tonight.recipe.image_key)}
              class="absolute inset-0 w-full h-full object-cover"
            />
            <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-black/30 to-transparent" />
          <% end %>
          <div class="relative h-full min-h-[60vh] flex flex-col justify-end p-10">
            <p class="text-white/60 text-lg mb-2">{gettext("Tonight")}</p>
            <h1 class="text-white text-5xl font-bold leading-tight mb-6">
              {@tonight.recipe.title}
            </h1>
            <div class="flex gap-4">
              <.link navigate={"/recipes/#{@tonight.recipe.id}"}
                class="bg-white text-black text-lg font-semibold px-8 py-4 rounded-2xl">
                {gettext("Start cooking")}
              </.link>
              <button phx-click="shuffle_tonight"
                class="bg-white/20 text-white text-lg font-semibold px-8 py-4 rounded-2xl border border-white/30">
                {gettext("Something else")}
              </button>
            </div>
          </div>
        <% else %>
          <div class="h-full min-h-[60vh] flex items-center justify-center">
            <p class="text-[color:var(--muted)] text-2xl">{gettext("No dinner planned.")}</p>
          </div>
        <% end %>
      </div>

      <%!-- Preset action buttons — large targets for dirty hands --%>
      <div class="bg-[color:var(--surface-raised)] px-10 py-5 flex gap-4">
        <%= if @tonight do %>
          <.link navigate={"/recipes/#{@tonight.recipe.id}"}
            class="flex-1 text-center py-4 rounded-2xl bg-[color:var(--surface)] text-[var(--text)] font-semibold text-base border border-[color:var(--hairline)]">
            {gettext("What's the recipe?")}
          </.link>
        <% end %>
        <button phx-click="shuffle_tonight"
          class="flex-1 text-center py-4 rounded-2xl bg-[color:var(--surface)] text-[var(--text)] font-semibold text-base border border-[color:var(--hairline)]">
          {gettext("Swap tonight")}
        </button>
        <button phx-click="mark_cooked"
          class="flex-1 text-center py-4 rounded-2xl bg-[color:var(--surface)] text-[var(--text)] font-semibold text-base border border-[color:var(--hairline)]">
          {gettext("I cooked it")}
        </button>
      </div>

      <%!-- Upcoming strip --%>
      <div class="bg-[color:var(--surface)] px-10 py-6 flex gap-6">
        <div :for={day <- @upcoming} class="flex-1 text-center">
          <p class="text-[color:var(--muted)] text-sm mb-1 uppercase tracking-wide">
            {day.day |> String.capitalize() |> String.slice(0, 3)}
          </p>
          <p class="text-[var(--text)] font-medium text-sm leading-snug">
            {if day.recipe, do: day.recipe.title, else: "–"}
          </p>
        </div>
      </div>

      <%!-- FAB for cooking questions — "Ask Tore" --%>
      <.link navigate="/chat"
        class="fixed bottom-8 right-8 bg-[color:var(--accent)] text-white shadow-xl flex items-center gap-2 px-5 py-4 rounded-full font-semibold text-base">
        <.icon name="hero-sparkles" class="size-6" />
        {gettext("Ask Tore")}
      </.link>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add kiosk route in router**

In `lib/tore_web/router.ex`, inside the kiosk device_auth pipeline scope, add:

```elixir
live "/kiosk", KioskHomeLive
```

The kiosk's Chromium points to `/kiosk`. The normal phone users go to `/`.

- [ ] **Step 3: Run the app and verify kiosk view**

```bash
mix phx.server
```

Navigate to http://localhost:4000/kiosk. Verify: large tonight hero, upcoming strip, FAB. No nav bar, no settings.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(kiosk): slim KioskHomeLive with tonight hero, upcoming strip, and FAB"
```

---

## Phase 7 — Family Memory

### Task 7.1: Add family_insights migration and schema

**Files:**
- Create: `priv/repo/migrations/20260528000019_create_family_insights.exs`
- Create: `lib/tore/family/family_insights.ex`
- Modify: `lib/tore/family.ex`

Each insight is a separate record with a `kind`, `confidence`, `evidence` (event IDs), and `status`. This allows individual insights to be dismissed, superseded, or updated without losing history.

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260528000019_create_family_insights.exs
defmodule Tore.Repo.Migrations.CreateFamilyInsights do
  use Ecto.Migration

  def change do
    create table(:family_insights) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :body, :text, null: false
      add :confidence, :float, null: false, default: 1.0
      add :evidence, :text
      add :status, :string, null: false, default: "active"
      add :generated_at, :utc_datetime
      timestamps()
    end

    create index(:family_insights, [:family_id])
    create index(:family_insights, [:family_id, :status])
  end
end
```

- [ ] **Step 2: Write the schema**

```elixir
# lib/tore/family/family_insights.ex
defmodule Tore.Family.FamilyInsights do
  use Ecto.Schema
  import Ecto.Changeset

  schema "family_insights" do
    field :kind, :string
    field :body, :string
    field :confidence, :float, default: 1.0
    field :evidence, :string
    field :status, :string, default: "active"
    field :generated_at, :utc_datetime
    belongs_to :family, Tore.Family.FamilySchema
    timestamps()
  end

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [:kind, :body, :confidence, :evidence, :status, :generated_at, :family_id])
    |> validate_required([:kind, :body, :family_id])
    |> validate_inclusion(:status, ["active", "superseded", "dismissed"])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
```

- [ ] **Step 3: Add insight helpers to `Tore.Family`**

```elixir
  alias Tore.Family.FamilyInsights

  @spec list_active_insights() :: [FamilyInsights.t()]
  def list_active_insights do
    family_id = get_family!().id
    Repo.all(
      from i in FamilyInsights,
        where: i.family_id == ^family_id and i.status == "active",
        order_by: [desc: i.confidence]
    )
  end

  @spec get_insights_body() :: String.t() | nil
  def get_insights_body do
    insights = list_active_insights()
    if insights == [], do: nil, else: Enum.map_join(insights, "\n", & &1.body)
  end

  @spec replace_insights([map()]) :: {:ok, [FamilyInsights.t()]} | {:error, term()}
  def replace_insights(insight_attrs_list) do
    family_id = get_family!().id
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Supersede existing active insights
      Repo.update_all(
        from(i in FamilyInsights, where: i.family_id == ^family_id and i.status == "active"),
        set: [status: "superseded"]
      )

      # Insert new insights
      Enum.map(insight_attrs_list, fn attrs ->
        %FamilyInsights{}
        |> FamilyInsights.changeset(Map.merge(attrs, %{family_id: family_id, generated_at: now}))
        |> Repo.insert!()
      end)
    end)
  end

  @spec dismiss_insight(integer()) :: {:ok, FamilyInsights.t()} | {:error, term()}
  def dismiss_insight(id) do
    family_id = get_family!().id
    insight = Repo.get_by!(FamilyInsights, id: id, family_id: family_id)
    insight |> FamilyInsights.changeset(%{status: "dismissed"}) |> Repo.update()
  end
```

- [ ] **Step 4: Write tests**

```elixir
# test/tore/family_insights_test.exs
defmodule Tore.FamilyInsightsTest do
  use Tore.DataCase, async: true

  alias Tore.Family

  setup do
    {:ok, family} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    {:ok, family: family}
  end

  test "get_insights_body/0 returns nil when no insights exist" do
    assert Family.get_insights_body() == nil
  end

  test "replace_insights/1 creates new active insight records" do
    attrs = [
      %{kind: "skip_pattern", body: "You skip Thursdays often.", confidence: 0.85}
    ]
    assert {:ok, [insight]} = Family.replace_insights(attrs)
    assert insight.kind == "skip_pattern"
    assert insight.status == "active"
    assert insight.confidence == 0.85
  end

  test "replace_insights/1 supersedes previous active insights" do
    {:ok, _} = Family.replace_insights([%{kind: "skip_pattern", body: "Old insight.", confidence: 0.7}])
    {:ok, _} = Family.replace_insights([%{kind: "skip_pattern", body: "New insight.", confidence: 0.9}])

    active = Family.list_active_insights()
    assert length(active) == 1
    assert hd(active).body == "New insight."
  end

  test "dismiss_insight/1 sets status to dismissed" do
    {:ok, [insight]} = Family.replace_insights([%{kind: "skip_pattern", body: "Test.", confidence: 0.8}])
    assert {:ok, dismissed} = Family.dismiss_insight(insight.id)
    assert dismissed.status == "dismissed"
    assert Family.list_active_insights() == []
  end

  test "get_insights_body/0 concatenates active insights" do
    Family.replace_insights([
      %{kind: "skip_pattern", body: "Skip Thursdays.", confidence: 0.9},
      %{kind: "cascade_success", body: "Chicken works well.", confidence: 0.7}
    ])
    body = Family.get_insights_body()
    assert String.contains?(body, "Skip Thursdays.")
    assert String.contains?(body, "Chicken works well.")
  end
end
```

- [ ] **Step 5: Run the tests**

```bash
mix ecto.migrate && mix test test/tore/family_insights_test.exs
```

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(insights): per-record family_insights with kind/confidence/evidence/status"
```

---

### Task 7.2: Add `synthesise_insights/1` LLM callback

**Files:**
- Modify: `lib/tore/llm.ex`
- Create: `priv/llm/prompts/synthesise_insights.eex`
- Modify: `lib/tore/adapters/open_router.ex`

- [ ] **Step 1: Add callback to LLM behaviour**

In `lib/tore/llm.ex`, add:

```elixir
@type insight_record :: %{kind: String.t(), body: String.t(), confidence: float()}
@callback synthesise_insights(context :: map()) :: {:ok, [insight_record()]} | {:error, term()}
```

- [ ] **Step 2: Write the prompt template**

```eex
<%# priv/llm/prompts/synthesise_insights.eex %>
You are building a persistent memory summary for a family's meal planning assistant.

Review the planning history below and produce 3-5 short insight records about this family's patterns.
Each insight should have a kind (one of: skip_pattern, cascade_success, cascade_failure, time_preference, ingredient_preference),
a confidence score (0.0–1.0), and a body (1-2 sentences, second person, specific and factual).

Focus on what will help plan better meals — patterns in skipping, cascade successes/failures, ingredient preferences, timing.
Do not mention dates. Use the previous insights as context — update or refine them, don't repeat verbatim.

Previous insights (may be empty):
<%= @previous_insights || "(none yet)" %>

Planning events from the last 8 weeks (newest first):
<%= @events_summary %>

Return JSON: {"insights": [{"kind": "skip_pattern", "body": "You skip...", "confidence": 0.85}, ...]}
```

- [ ] **Step 3: Implement in OpenRouter adapter**

```elixir
@impl Tore.LLM
def synthesise_insights(context) do
  system = "You analyse meal planning history and return structured insight records. Return only valid JSON."
  user = EEx.eval_file(
    Application.app_dir(:tore, "priv/llm/prompts/synthesise_insights.eex"),
    [assigns: context]
  )

  case chat(system, user) do
    {:ok, %{"insights" => insights}, _usage} when is_list(insights) ->
      parsed = Enum.map(insights, fn i ->
        %{kind: i["kind"], body: i["body"], confidence: i["confidence"] || 0.5}
      end)
      {:ok, parsed}
    {:ok, _, _} -> {:error, :invalid_response}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(insights): add synthesise_insights LLM callback and prompt"
```

---

### Task 7.3: Create the InsightsHandler with importance weighting and Quantum job

**Files:**
- Create: `lib/tore/handlers/insights_handler.ex`
- Modify: `lib/tore/scheduler.ex`

- [ ] **Step 1: Write InsightsHandler**

```elixir
# lib/tore/handlers/insights_handler.ex
defmodule Tore.Handlers.InsightsHandler do
  @moduledoc """
  Two responsibilities:
  1. synthesise/0 — weekly LLM job: loads 8 weeks of events, writes Tier 1 stable patterns blob.
  2. this_week_context/0 — cheap, live: formats current week events as Tier 2 text. No LLM call.
  """

  alias Tore.Family

  @llm Application.compile_env(:tore, :llm_client)
  @lookback_weeks 8

  # Event importance weights for synthesis prompt ordering
  @event_weights %{
    "MealSkipped" => 10,
    "RecipeAssigned" => 5,    # after a swap — medium signal
    "MarkLeftover" => 4,
    "PlanGenerated" => 1
  }

  @spec synthesise() :: {:ok, [map()]} | {:error, term()}
  def synthesise do
    previous_insights = Family.get_insights_body()
    events_summary = load_weighted_events_summary(@lookback_weeks)
    context = %{previous_insights: previous_insights, events_summary: events_summary}

    with {:ok, insight_attrs} <- @llm.synthesise_insights(context),
         {:ok, records} <- Family.replace_insights(insight_attrs) do
      {:ok, records}
    end
  end

  @spec this_week_context() :: String.t()
  def this_week_context do
    import Ecto.Query

    week_start =
      Date.utc_today()
      |> then(fn d -> Date.add(d, -(Date.day_of_week(d) - 1)) end)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    events =
      Tore.Repo.all(
        from e in Tore.EventStore.EventRecord,
          where: e.stream_type == "planning" and e.inserted_at >= ^week_start,
          order_by: [asc: e.id],
          select: %{event_type: e.event_type, data: e.data}
      )

    if events == [] do
      "This week: no planning activity yet."
    else
      lines =
        events
        |> Enum.map(fn e ->
          data = Jason.decode!(e.data)
          format_event(e.event_type, data)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(". ")

      "This week: #{lines}."
    end
  end

  defp load_weighted_events_summary(weeks) do
    import Ecto.Query

    cutoff = DateTime.add(DateTime.utc_now(), -weeks * 7 * 86_400, :second)

    Tore.Repo.all(
      from e in Tore.EventStore.EventRecord,
        where: e.stream_type == "planning" and e.inserted_at >= ^cutoff,
        order_by: [desc: e.id],
        limit: 300,
        select: %{event_type: e.event_type, data: e.data}
    )
    |> Enum.sort_by(fn e -> Map.get(@event_weights, e.event_type, 1) end, :desc)
    |> Enum.map(fn e ->
      data = Jason.decode!(e.data)
      weight = Map.get(@event_weights, e.event_type, 1)
      "[importance:#{weight}] #{format_event(e.event_type, data)}"
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_event("MealSkipped", %{"slot_key" => slot}), do: "Skipped #{slot}"
  defp format_event("RecipeAssigned", %{"slot_key" => slot, "recipe_id" => id}), do: "Assigned recipe #{id} to #{slot}"
  defp format_event("MarkLeftover", %{"slot_key" => slot}), do: "Marked #{slot} as leftover"
  defp format_event("PlanGenerated", _), do: "Plan generated"
  defp format_event(type, _), do: type
end
```

- [ ] **Step 2: Add the Quantum job to scheduler**

Open `lib/tore/scheduler.ex`. Add a weekly insights synthesis job (Sunday 20:00, after plan generation):

```elixir
{"0 20 * * 0", {Tore.Handlers.InsightsHandler, :synthesise, []}}
```

Verify the existing scheduler file format and match it exactly (check whether it uses keyword list or map syntax).

- [ ] **Step 3: Write tests for InsightsHandler**

```elixir
# test/tore/handlers/insights_handler_test.exs
defmodule Tore.Handlers.InsightsHandlerTest do
  use Tore.DataCase, async: true
  import Mox

  alias Tore.Handlers.InsightsHandler
  alias Tore.Family

  setup :verify_on_exit!

  setup do
    {:ok, _family} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "synthesise/0 calls LLM and stores per-record insights" do
    Tore.LLMMock
    |> expect(:synthesise_insights, fn _context ->
      {:ok, [
        %{kind: "skip_pattern", body: "You tend to skip Thursday dinners.", confidence: 0.85},
        %{kind: "cascade_success", body: "Chicken cascades work well.", confidence: 0.72}
      ]}
    end)

    assert {:ok, records} = InsightsHandler.synthesise()
    assert length(records) == 2
    assert Family.list_active_insights() |> length() == 2
  end

  test "synthesise/0 passes previous insights as context" do
    Family.replace_insights([%{kind: "skip_pattern", body: "Old insight.", confidence: 0.7}])

    Tore.LLMMock
    |> expect(:synthesise_insights, fn context ->
      assert String.contains?(context.previous_insights, "Old insight.")
      {:ok, [%{kind: "skip_pattern", body: "Updated insight.", confidence: 0.9}]}
    end)

    assert {:ok, _} = InsightsHandler.synthesise()
  end

  test "this_week_context/0 returns a string even with no events" do
    result = InsightsHandler.this_week_context()
    assert is_binary(result)
    assert String.starts_with?(result, "This week:")
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/tore/handlers/insights_handler_test.exs
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(insights): InsightsHandler with importance weighting, this_week_context, and Quantum job"
```

---

### Task 7.4: Build the chat system prompt and inject both memory tiers

**Files:**
- Create: `lib/tore/chat/system_prompt.ex`
- Modify: `lib/tore/handlers/chat_handler.ex`
- Modify: `lib/tore/handlers/planning_handler.ex`
- Modify: `priv/llm/prompts/plan_weekly.eex`
- Modify: `priv/llm/prompts/parse_assistant_command.eex`

- [ ] **Step 1: Create `Tore.Chat.SystemPrompt`**

This module assembles the full system prompt for the chat assistant from all context sources:

```elixir
# lib/tore/chat/system_prompt.ex
defmodule Tore.Chat.SystemPrompt do
  @moduledoc """
  Assembles the chat assistant system prompt from all context tiers.

  Section order:
    1. Role + app context (static)
    2. Hard constraints (family dietary/allergies)
    3. Tier 1: stable patterns (weekly synthesis blob)
    4. Tier 2: this week context (live from event store)
    5. Situational context (today, pantry snapshot, deals)
  """

  alias Tore.{Family, Pantry, Deals, Handlers.InsightsHandler}

  @spec build() :: String.t()
  def build do
    family = Family.get_family!()
    constraints = Family.prefs_to_dietary_guidance(family)
    stable_patterns = Family.get_insights_body()
    this_week = InsightsHandler.this_week_context()
    pantry = pantry_snapshot()
    deals = deals_snapshot()
    today = Date.utc_today()

    sections = [
      role_section(family),
      constraints_section(constraints),
      stable_patterns_section(stable_patterns),
      this_week_section(this_week),
      situational_section(today, pantry, deals)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp role_section(family) do
    """
    You are the AI assistant for Tore, a meal planning app for the #{family.name} family.
    You can have a conversation AND take actions that update the app directly.
    When you take an action, confirm what you did in one warm, brief sentence.
    Never nag. Never ask for confirmation before acting — just act and confirm.
    Speak warmly but briefly, like a knowledgeable friend.
    """
    |> String.trim()
  end

  defp constraints_section(nil), do: nil
  defp constraints_section(constraints) do
    "Hard constraints — never violate these:\n#{constraints}"
  end

  defp stable_patterns_section(nil), do: nil
  defp stable_patterns_section(""), do: nil
  defp stable_patterns_section(body) do
    "Patterns (what you know about this family from history):\n#{body}"
  end

  defp this_week_section(context) do
    "Current week:\n#{context}"
  end

  defp situational_section(today, pantry, deals) do
    lines = ["Today: #{today} (#{day_name(Date.day_of_week(today))})"]
    lines = if pantry != "", do: lines ++ ["Pantry (approximate): #{pantry}"], else: lines
    lines = if deals != "", do: lines ++ ["Deals this week: #{deals}"], else: lines
    Enum.join(lines, "\n")
  end

  defp pantry_snapshot do
    Pantry.list_inventory()
    |> Enum.take(20)
    |> Enum.map(fn i -> "#{i.name}#{if i.quantity, do: " (#{i.quantity}#{i.unit})", else: ""}" end)
    |> Enum.join(", ")
  end

  defp deals_snapshot do
    Deals.list_current()
    |> Enum.take(10)
    |> Enum.map(fn d -> "#{d.product_name}#{if d.price, do: " #{d.price}kr", else: ""}" end)
    |> Enum.join(", ")
  end

  defp day_name(1), do: "Monday"
  defp day_name(2), do: "Tuesday"
  defp day_name(3), do: "Wednesday"
  defp day_name(4), do: "Thursday"
  defp day_name(5), do: "Friday"
  defp day_name(6), do: "Saturday"
  defp day_name(7), do: "Sunday"
end
```

- [ ] **Step 2: Write a test for SystemPrompt**

```elixir
# test/tore/chat/system_prompt_test.exs
defmodule Tore.Chat.SystemPromptTest do
  use Tore.DataCase, async: true

  alias Tore.{Chat.SystemPrompt, Family}

  setup do
    {:ok, _} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "build/0 returns a non-empty string" do
    result = SystemPrompt.build()
    assert is_binary(result)
    assert String.length(result) > 50
  end

  test "build/0 includes role section" do
    result = SystemPrompt.build()
    assert String.contains?(result, "Rydholm")
    assert String.contains?(result, "Tore")
  end

  test "build/0 includes this week context" do
    result = SystemPrompt.build()
    assert String.contains?(result, "This week:")
  end

  test "build/0 includes stable patterns when insights exist" do
    {:ok, _} = Family.upsert_insights("You skip Thursdays often.")
    result = SystemPrompt.build()
    assert String.contains?(result, "You skip Thursdays often.")
  end
end
```

- [ ] **Step 3: Run the test**

```bash
mix test test/tore/chat/system_prompt_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 4: Wire SystemPrompt into ChatHandler**

In `lib/tore/handlers/chat_handler.ex`, update `handle_text/2` to build the system prompt and pass it to the LLM:

```elixir
@spec handle_text(String.t(), map()) ::
  {:ok, String.t(), Action.t() | nil} | {:error, term()}
def handle_text(input, _context) do
  system_prompt = Tore.Chat.SystemPrompt.build()
  with {:ok, parsed, _usage} <- @llm.parse_assistant_command(input, %{system_prompt: system_prompt}) do
    dispatch(parsed)
  end
end
```

Update `parse_assistant_command/2` in the OpenRouter adapter to use the system prompt from context if provided:

```elixir
@impl Tore.LLM
def parse_assistant_command(input, context) do
  system = Map.get(context, :system_prompt) ||
    "You are the AI assistant for Tore meal planner. Return only valid JSON."

  user = EEx.eval_file(
    Application.app_dir(:tore, "priv/llm/prompts/parse_assistant_command.eex"),
    [assigns: Map.put(context, :input, input)]
  )

  case chat(system, user) do
    {:ok, %{"action" => _} = result, usage} -> {:ok, result, usage}
    {:ok, _, _} -> {:error, :invalid_response}
    {:error, reason} -> {:error, reason}
  end
end
```

Update `priv/llm/prompts/parse_assistant_command.eex` — since the system prompt now carries all context, simplify the user prompt to just the input:

```eex
<%# priv/llm/prompts/parse_assistant_command.eex %>
Parse this user input into a structured action. Return JSON only.

Supported actions:
- add_pantry_item: { "action": "add_pantry_item", "name": "...", "quantity": 1.0, "unit": "kg", "expires_at": "YYYY-MM-DD" }
- remove_pantry_item: { "action": "remove_pantry_item", "name": "..." }
- add_grocery_item: { "action": "add_grocery_item", "name": "...", "quantity": 1, "unit": "st" }
- remove_grocery_item: { "action": "remove_grocery_item", "name": "..." }
- assign_recipe: { "action": "assign_recipe", "slot_key": "wed_dinner", "recipe_title": "..." }
- skip_meal: { "action": "skip_meal", "slot_key": "thu_dinner" }
- reshuffle_week: { "action": "reshuffle_week", "constraint": "..." }
- unknown: { "action": "unknown", "reply": "..." }

User input: <%= @input %>
```

- [ ] **Step 5: Inject both memory tiers into planning prompts**

In `lib/tore/handlers/planning_handler.ex`, update `build_plan_context/4`:

```elixir
%{
  recipes: recipes,
  slot_keys: slot_keys,
  pins: state.pins,
  pantry: [],
  deals: Enum.map(Deals.list_current(), fn d ->
    "#{d.product_name}#{if d.price, do: " #{d.price}kr", else: ""}"
  end),
  recent_recipes: [],
  week_start: week_start,
  mode: mode,
  dietary_guidance: dietary_guidance,
  family_insights: Tore.Family.get_insights_body(),
  this_week_context: Tore.Handlers.InsightsHandler.this_week_context()
}
```

In `priv/llm/prompts/plan_weekly.eex`, add after dietary guidance:

```eex
<%= if @family_insights && @family_insights != "" do %>
Family patterns (from history — ordered by confidence):
<%= @family_insights %>
<% end %>

Current week so far:
<%= @this_week_context %>
```

- [ ] **Step 6: Run the full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(insights): SystemPrompt with two-tier memory injection into chat and planning"
```

---

---

## Phase 8 — AI-Native UX Primitives

### Task 8.1: Counter Notes — migration, schema, and surface query

**Files:**
- Create: `priv/repo/migrations/20260528000020_create_counter_notes.exs`
- Create: `lib/tore/counter_notes/counter_note.ex`
- Create: `lib/tore/counter_notes.ex`

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260528000020_create_counter_notes.exs
defmodule Tore.Repo.Migrations.CreateCounterNotes do
  use Ecto.Migration

  def change do
    create table(:counter_notes) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :surface, :string, null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :commands, :text
      add :confidence, :string, null: false, default: "medium"
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime
      timestamps(updated_at: false)
    end

    create index(:counter_notes, [:family_id, :surface, :status])
  end
end
```

- [ ] **Step 2: Write the schema**

```elixir
# lib/tore/counter_notes/counter_note.ex
defmodule Tore.CounterNotes.CounterNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "counter_notes" do
    field :surface, :string
    field :kind, :string
    field :title, :string
    field :body, :string
    field :commands, :string
    field :confidence, :string, default: "medium"
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    belongs_to :family, Tore.Family.FamilySchema
    timestamps(updated_at: false)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:surface, :kind, :title, :body, :commands, :confidence, :status, :expires_at, :family_id])
    |> validate_required([:surface, :kind, :title, :body, :family_id])
    |> validate_inclusion(:surface, ~w(home week groceries pantry deals))
    |> validate_inclusion(:kind, ~w(deal_opportunity plan_repair pantry_assumption habit_pattern))
    |> validate_inclusion(:confidence, ~w(low medium high))
    |> validate_inclusion(:status, ~w(pending accepted ignored expired))
  end
end
```

- [ ] **Step 3: Write the CounterNotes context**

```elixir
# lib/tore/counter_notes.ex
defmodule Tore.CounterNotes do
  import Ecto.Query
  alias Tore.{Repo, CounterNotes.CounterNote, Family}

  @spec list_for_surface(String.t()) :: [CounterNote.t()]
  def list_for_surface(surface) do
    family_id = Family.get_family!().id
    now = DateTime.utc_now()

    Repo.all(
      from n in CounterNote,
        where: n.family_id == ^family_id
          and n.surface == ^surface
          and n.status == "pending"
          and (is_nil(n.expires_at) or n.expires_at > ^now),
        order_by: [asc: n.inserted_at],
        limit: 3
    )
  end

  @spec create(map()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    family_id = Family.get_family!().id
    %CounterNote{}
    |> CounterNote.changeset(Map.put(attrs, :family_id, family_id))
    |> Repo.insert()
  end

  @spec accept(integer()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def accept(id) do
    family_id = Family.get_family!().id
    note = Repo.get_by!(CounterNote, id: id, family_id: family_id)
    note |> CounterNote.changeset(%{status: "accepted"}) |> Repo.update()
  end

  @spec ignore(integer()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def ignore(id) do
    family_id = Family.get_family!().id
    note = Repo.get_by!(CounterNote, id: id, family_id: family_id)
    note |> CounterNote.changeset(%{status: "ignored"}) |> Repo.update()
  end

  @spec expire_stale() :: {integer(), nil}
  def expire_stale do
    now = DateTime.utc_now()
    Repo.update_all(
      from(n in CounterNote,
        where: n.status == "pending" and not is_nil(n.expires_at) and n.expires_at <= ^now),
      set: [status: "expired"]
    )
  end
end
```

- [ ] **Step 4: Write tests**

```elixir
# test/tore/counter_notes_test.exs
defmodule Tore.CounterNotesTest do
  use Tore.DataCase, async: true
  alias Tore.{CounterNotes, Family}

  setup do
    {:ok, _} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "list_for_surface/1 returns pending notes for the surface" do
    {:ok, _} = CounterNotes.create(%{
      surface: "home", kind: "deal_opportunity",
      title: "Chicken deal", body: "ICA has chicken 20% off."
    })
    {:ok, _} = CounterNotes.create(%{
      surface: "pantry", kind: "pantry_assumption",
      title: "Rice", body: "Probably have rice."
    })

    home_notes = CounterNotes.list_for_surface("home")
    assert length(home_notes) == 1
    assert hd(home_notes).surface == "home"
  end

  test "ignore/1 removes note from surface" do
    {:ok, note} = CounterNotes.create(%{
      surface: "home", kind: "deal_opportunity",
      title: "Test", body: "Test."
    })
    {:ok, _} = CounterNotes.ignore(note.id)
    assert CounterNotes.list_for_surface("home") == []
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix ecto.migrate && mix test test/tore/counter_notes_test.exs
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(counter-notes): migration, schema, and context for ambient AI suggestions"
```

---

### Task 8.2: Render counter notes on home and week view

**Files:**
- Modify: `lib/tore_web/live/home_live.ex`
- Modify: `lib/tore_web/live/home_live.html.heex`

- [ ] **Step 1: Load counter notes in HomeLive mount**

In `lib/tore_web/live/home_live.ex`, update `mount/3`:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket), do: Phoenix.PubSub.subscribe(Tore.PubSub, "plan")
  {:ok, state} = PlanningHandler.load_plan(@plan_id)
  today = Date.utc_today()
  week_start = week_start(today)

  {:ok, assign(socket,
    state: state,
    today: today,
    week_start: week_start,
    tonight: tonight_slot(state, today),
    week_slots: week_slots(state, week_start),
    shuffling: false,
    counter_notes: Tore.CounterNotes.list_for_surface("home")
  )}
end
```

Add event handlers:

```elixir
def handle_event("accept_note", %{"id" => id}, socket) do
  Tore.CounterNotes.accept(String.to_integer(id))
  {:noreply, assign(socket, counter_notes: Tore.CounterNotes.list_for_surface("home"))}
end

def handle_event("ignore_note", %{"id" => id}, socket) do
  Tore.CounterNotes.ignore(String.to_integer(id))
  {:noreply, assign(socket, counter_notes: Tore.CounterNotes.list_for_surface("home"))}
end
```

- [ ] **Step 2: Add counter note rendering to the template**

Add after the week strip in `home_live.html.heex`:

```heex
<%!-- Counter notes --%>
<%= for note <- @counter_notes do %>
  <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4 mb-3">
    <p class="text-xs text-[color:var(--muted)] mb-1 font-medium uppercase tracking-wide">
      {gettext("Tore noticed")}
    </p>
    <p class="font-semibold text-[var(--text)] text-sm mb-1">{note.title}</p>
    <p class="text-sm text-[color:var(--muted)] mb-3">{note.body}</p>
    <div class="flex gap-2">
      <button phx-click="accept_note" phx-value-id={note.id}
        class="flex-1 py-2 rounded-xl bg-[color:var(--accent)] text-white text-xs font-medium">
        {gettext("Accept")}
      </button>
      <button phx-click="ignore_note" phx-value-id={note.id}
        class="px-4 py-2 rounded-xl border border-[color:var(--hairline)] text-[color:var(--muted)] text-xs font-medium">
        {gettext("Ignore")}
      </button>
    </div>
  </div>
<% end %>
```

- [ ] **Step 3: Start server and verify notes appear on home screen**

```bash
mix phx.server
```

Open http://localhost:4000. Manually insert a test note via `iex -S mix`:

```elixir
Tore.CounterNotes.create(%{surface: "home", kind: "deal_opportunity", title: "Chicken deal", body: "ICA has chicken thighs 20% off."})
```

Verify the note appears. Click Ignore — verify it disappears.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(counter-notes): render ambient AI notes on home screen"
```

---

### Task 8.3: Week Modes — migration, schema, context, and planning integration

**Files:**
- Create: `priv/repo/migrations/20260528000021_create_week_modes.exs`
- Create: `lib/tore/week_mode.ex`
- Modify: `lib/tore/handlers/planning_handler.ex`
- Modify: `priv/llm/prompts/plan_weekly.eex`

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260528000021_create_week_modes.exs
defmodule Tore.Repo.Migrations.CreateWeekModes do
  use Ecto.Migration

  def change do
    create table(:week_modes) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :mode, :string, null: false, default: "normal"
      add :week_start, :date, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:week_modes, [:family_id, :week_start])
  end
end
```

- [ ] **Step 2: Write the WeekMode context**

```elixir
# lib/tore/week_mode.ex
defmodule Tore.WeekMode do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Tore.{Repo, Family}

  @valid_modes ~w(normal low_effort budget_week use_pantry more_leftovers
    high_protein freezer_week guest_week)

  schema "week_modes" do
    field :mode, :string, default: "normal"
    field :week_start, :date
    belongs_to :family, Tore.Family.FamilySchema
    timestamps(updated_at: false)
  end

  def changeset(wm, attrs) do
    wm
    |> cast(attrs, [:mode, :week_start, :family_id])
    |> validate_required([:mode, :week_start, :family_id])
    |> validate_inclusion(:mode, @valid_modes)
  end

  @spec get_current_mode() :: String.t()
  def get_current_mode do
    family_id = Family.get_family!().id
    week_start = current_week_start()

    case Repo.one(from wm in __MODULE__,
           where: wm.family_id == ^family_id and wm.week_start == ^week_start) do
      nil -> "normal"
      wm -> wm.mode
    end
  end

  @spec set_mode(String.t()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t()}
  def set_mode(mode) do
    family_id = Family.get_family!().id
    week_start = current_week_start()
    attrs = %{mode: mode, week_start: week_start, family_id: family_id}

    case Repo.one(from wm in __MODULE__,
           where: wm.family_id == ^family_id and wm.week_start == ^week_start) do
      nil -> %__MODULE__{}
      existing -> existing
    end
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec mode_prompt_fragment(String.t()) :: String.t() | nil
  def mode_prompt_fragment("normal"), do: nil
  def mode_prompt_fragment("low_effort") do
    "Current week mode: Low effort. Prefer ≤30 minute meals. Fewer unique cooking sessions. More leftovers where possible. Do not change pinned slots."
  end
  def mode_prompt_fragment("budget_week") do
    "Current week mode: Budget week. Prioritise meals that use on-sale ingredients and pantry staples. Minimise unique grocery items."
  end
  def mode_prompt_fragment("use_pantry") do
    "Current week mode: Use pantry. Prioritise meals that use existing pantry inventory. Avoid new ingredients where possible."
  end
  def mode_prompt_fragment("more_leftovers") do
    "Current week mode: More leftovers. Prefer recipes that produce more servings. Plan for intentional leftover meals."
  end
  def mode_prompt_fragment("high_protein") do
    "Current week mode: High protein. Prefer high-protein meals. Increase meat/fish/legume component ratio."
  end
  def mode_prompt_fragment("freezer_week") do
    "Current week mode: Freezer week. Prioritise using frozen ingredients. Suggest meals compatible with freezer staples."
  end
  def mode_prompt_fragment("guest_week") do
    "Current week mode: Guest week. Plan for larger portions and more impressive recipes suitable for guests."
  end
  def mode_prompt_fragment(_), do: nil

  defp current_week_start do
    today = Date.utc_today()
    Date.add(today, -(Date.day_of_week(today) - 1))
  end
end
```

- [ ] **Step 3: Add mode prompt to `plan_weekly.eex`**

In `priv/llm/prompts/plan_weekly.eex`, add after the family insights block:

```eex
<%= if @week_mode_fragment do %>
<%= @week_mode_fragment %>
<% end %>
```

- [ ] **Step 4: Pass week mode to planning context**

In `lib/tore/handlers/planning_handler.ex`, in `build_plan_context/4`, add:

```elixir
week_mode_fragment: Tore.WeekMode.mode_prompt_fragment(Tore.WeekMode.get_current_mode())
```

- [ ] **Step 5: Write a test**

```elixir
# test/tore/week_mode_test.exs
defmodule Tore.WeekModeTest do
  use Tore.DataCase, async: true
  alias Tore.{WeekMode, Family}

  setup do
    {:ok, _} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "get_current_mode/0 returns 'normal' when no mode set" do
    assert WeekMode.get_current_mode() == "normal"
  end

  test "set_mode/1 and get_current_mode/0 round-trip" do
    {:ok, _} = WeekMode.set_mode("low_effort")
    assert WeekMode.get_current_mode() == "low_effort"
  end

  test "set_mode/1 with invalid mode returns error" do
    assert {:error, _} = WeekMode.set_mode("turbo_mode")
  end

  test "mode_prompt_fragment/1 returns nil for normal mode" do
    assert WeekMode.mode_prompt_fragment("normal") == nil
  end

  test "mode_prompt_fragment/1 returns fragment for low_effort" do
    fragment = WeekMode.mode_prompt_fragment("low_effort")
    assert String.contains?(fragment, "Low effort")
  end
end
```

- [ ] **Step 6: Run tests**

```bash
mix ecto.migrate && mix test test/tore/week_mode_test.exs
```

Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(week-modes): temporary planning bias per week, injected into planning prompt"
```

---

### Task 8.4: Plan Health — derived state indicator on week view

**Files:**
- Create: `lib/tore/plan_health.ex`
- Modify: `lib/tore_web/live/home_live.ex`

- [ ] **Step 1: Write PlanHealth module**

```elixir
# lib/tore/plan_health.ex
defmodule Tore.PlanHealth do
  @moduledoc """
  Derives a compact health status for the current week plan from event store state.
  No LLM call. Updates on any plan event.
  """

  @type status :: :ready | :flexible | :fragile | :stale | :unplanned

  @spec compute(map()) :: {status(), String.t()}
  def compute(plan_state) do
    slots = plan_state.slots || %{}
    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))

    week_keys =
      0..4
      |> Enum.map(fn offset ->
        date = Date.add(week_start, offset)
        day = date |> Date.day_of_week() |> day_atom()
        "#{day}_dinner"
      end)

    assigned_count = Enum.count(week_keys, fn k ->
      slot = Map.get(slots, k)
      slot && slot.recipe_id
    end)

    total = length(week_keys)

    cond do
      assigned_count == 0 -> {:unplanned, "No plan for this week yet."}
      assigned_count < total -> {:flexible, "#{total - assigned_count} slot(s) unplanned."}
      true -> {:ready, "Plan looks good for the week."}
    end
  end

  defp day_atom(1), do: "mon"
  defp day_atom(2), do: "tue"
  defp day_atom(3), do: "wed"
  defp day_atom(4), do: "thu"
  defp day_atom(5), do: "fri"
  defp day_atom(6), do: "sat"
  defp day_atom(7), do: "sun"
end
```

- [ ] **Step 2: Add plan health to HomeLive**

In `home_live.ex`, in `mount/3`, add:

```elixir
plan_health: Tore.PlanHealth.compute(state)
```

In `handle_info({:events, ...})`, update plan_health on refresh:

```elixir
plan_health: Tore.PlanHealth.compute(state)
```

- [ ] **Step 3: Render plan health badge**

In `home_live.html.heex`, add a small status badge below the week strip:

```heex
<div class={[
  "text-xs font-medium px-3 py-1.5 rounded-full inline-flex items-center gap-1.5 mt-2",
  elem(@plan_health, 0) == :ready && "bg-green-100 text-green-700",
  elem(@plan_health, 0) == :flexible && "bg-yellow-100 text-yellow-700",
  elem(@plan_health, 0) == :fragile && "bg-orange-100 text-orange-700",
  elem(@plan_health, 0) == :unplanned && "bg-[color:var(--surface-raised)] text-[color:var(--muted)]"
]}>
  {elem(@plan_health, 1)}
</div>
```

- [ ] **Step 4: Write a test**

```elixir
# test/tore/plan_health_test.exs
defmodule Tore.PlanHealthTest do
  use ExUnit.Case, async: true
  alias Tore.PlanHealth

  test "returns :unplanned when no slots assigned" do
    assert {status, _} = PlanHealth.compute(%{slots: %{}})
    assert status == :unplanned
  end

  test "returns :ready when all weekday slots assigned" do
    slots = ~w(mon tue wed thu fri)
    |> Enum.map(fn day -> {"#{day}_dinner", %{recipe_id: 1}} end)
    |> Map.new()
    assert {:ready, _} = PlanHealth.compute(%{slots: slots})
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/tore/plan_health_test.exs
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(plan-health): derive compact plan status, show on home screen"
```

---

### Task 8.5: Contextual Command Bar on week view

**Files:**
- Modify: `lib/tore_web/live/week_live.ex` (or create if not yet built)
- Modify: corresponding template

The planner/week view gains a one-line NL command bar at the top:

- [ ] **Step 1: Add command bar input to planner template**

```heex
<form phx-submit="quick_command" class="mb-4">
  <input
    type="text"
    name="command"
    placeholder={gettext("Tell Tore what to change…")}
    autocomplete="off"
    class="w-full rounded-xl border border-[color:var(--hairline)] bg-[color:var(--surface)] px-4 py-3 text-sm text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
  />
</form>
```

- [ ] **Step 2: Handle the event**

In the planner LiveView's handle_event:

```elixir
def handle_event("quick_command", %{"command" => command}, socket) when command != "" do
  context = Tore.Chat.SystemPrompt.build()
  {reply, action} =
    case Tore.Handlers.ChatHandler.handle_text(command, %{system_prompt: context}) do
      {:ok, r, a} -> {r, a}
      {:error, _} -> {"Something went wrong.", nil}
    end
  {:noreply, assign(socket, quick_reply: reply, quick_action: action)}
end

def handle_event("quick_command", %{"command" => ""}, socket) do
  {:noreply, socket}
end
```

Render the reply inline when present:

```heex
<%= if assigns[:quick_reply] do %>
  <div class="rounded-xl bg-[color:var(--surface-raised)] px-4 py-3 text-sm text-[var(--text)] mb-4">
    {@quick_reply}
  </div>
<% end %>
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(planner): contextual NL command bar on week view"
```

---

### Task 8.6: Cooking Substitution in recipe/cooking screen

**Files:**
- Modify: `lib/tore_web/live/cooking_screen_live.ex` (or recipe detail live view)
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/adapters/open_router.ex`

- [ ] **Step 1: Add `suggest_substitution/2` LLM callback**

In `lib/tore/llm.ex`, add:

```elixir
@callback suggest_substitution(missing :: String.t(), recipe_context :: String.t()) ::
  {:ok, %{suggestion: String.t(), updated_steps: String.t() | nil}} | {:error, term()}
```

- [ ] **Step 2: Implement in OpenRouter adapter**

```elixir
@impl Tore.LLM
def suggest_substitution(missing, recipe_context) do
  system = """
  You are a cooking assistant. The user is missing an ingredient.
  Suggest a practical substitution and, if needed, how to adjust the recipe steps.
  Return JSON: {"suggestion": "...", "updated_steps": "..." or null}
  """
  user = "Recipe: #{recipe_context}\nMissing: #{missing}"

  case chat(system, user) do
    {:ok, %{"suggestion" => suggestion} = result, _} ->
      {:ok, %{suggestion: suggestion, updated_steps: result["updated_steps"]}}
    {:ok, _, _} -> {:error, :invalid_response}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 3: Add substitution UI to the cooking/recipe screen**

In the cooking screen LiveView, add a "Missing something?" collapsible input:

```heex
<div class="mt-6 border-t border-[color:var(--hairline)] pt-4">
  <button phx-click="toggle_substitution"
    class="text-sm text-[color:var(--muted)] flex items-center gap-1">
    <.icon name="hero-question-mark-circle" class="size-4" />
    {gettext("Missing something?")}
  </button>

  <%= if @show_substitution do %>
    <form phx-submit="get_substitution" class="mt-3 flex gap-2">
      <input type="text" name="missing"
        placeholder={gettext("e.g. crème fraîche")}
        class="flex-1 rounded-xl border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2.5 text-sm" />
      <button type="submit"
        class="bg-[color:var(--accent)] text-white rounded-xl px-4 py-2.5 text-sm font-medium">
        {gettext("Ask")}
      </button>
    </form>

    <%= if @substitution do %>
      <div class="mt-3 rounded-xl bg-[color:var(--surface-raised)] p-4 text-sm text-[var(--text)]">
        {@substitution.suggestion}
      </div>
    <% end %>
  <% end %>
</div>
```

Add event handlers:

```elixir
def handle_event("toggle_substitution", _params, socket) do
  {:noreply, assign(socket, show_substitution: !socket.assigns[:show_substitution])}
end

def handle_event("get_substitution", %{"missing" => missing}, socket) when missing != "" do
  recipe_context = socket.assigns.recipe.title
  case Tore.LLM.impl().suggest_substitution(missing, recipe_context) do
    {:ok, result} -> {:noreply, assign(socket, substitution: result)}
    {:error, _} -> {:noreply, socket}
  end
end
```

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(cooking): ingredient substitution — missing something? LLM suggests swap"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| Home screen: tonight + week strip | Task 3.1 |
| Photo alongside recipe name (not behind text) | Task 3.1 template — side-by-side layout |
| "Something else" shuffle button | Task 3.1, 6.1 templates |
| FAB opens chat ("Ask Tore") | Task 4.4 |
| NL commands → handlers | Task 4.2, 4.3 |
| Risk-tiered actions (Tier 1/2/3) | Task 4.1 Action struct with `tier` field and `@tier_map` |
| AIOperation/correlation layer | Task 1.5 `ai_operations` migration |
| Photo classification, grouping | Task 5.1, 5.2 |
| Photo confidence scores + disambiguation | Task 5.1 classify callback, 5.2 PhotoPipeline |
| Multi-photo per class grouped | PhotoPipeline.group_by_class |
| Polymorphic review screen | Task 5.4 |
| "Nothing saved yet" on review screen | Task 5.4 template |
| Pantry confidence model (confirmed/probably_have/etc) | Task 1.5 pantry_items migration `confidence` column |
| Family hierarchy | Task 1.2–1.5 |
| Garage object storage | Task 2.1–2.3 |
| Kiosk: tonight + upcoming + preset buttons + FAB | Task 6.1 — preset buttons + "Ask Tore" FAB |
| Pantry as inference (no CRUD push) | HomeLive has no pantry entry point; pantry writes go through chat |
| Cascade algorithm preserved | PlanningHandler and prompts untouched |
| Cascade-aware reshuffling | Existing PlanningHandler.generate_plan covers this |
| Background AI produces drafts only | Draft acceptance in week view — plan generation fires draft state |
| Per-record family_insights (kind/confidence/evidence/status) | Task 7.1–7.4 |
| Tier 1 stable patterns (weekly LLM synthesis) | Task 7.2, 7.3 |
| Tier 2 this-week context (live, no LLM) | Task 7.3 `this_week_context/0` |
| Chat system prompt with all memory tiers | Task 7.4 `SystemPrompt.build/0` |
| Memory injected into planning prompts | Task 7.4 |
| Importance-weighted event ordering for synthesis | Task 7.3 `@event_weights` |
| Weekly Quantum job to synthesise | Task 7.3 |
| Insights dismissible per record | Task 7.1 `dismiss_insight/1` |

| Counter notes (ambient AI suggestions inline) | Task 8.1, 8.2 |
| Week modes (temporary planning biases) | Task 8.3 |
| Plan health indicator | Task 8.4 |
| Contextual command bar on week view | Task 8.5 |
| Cooking substitution ("Missing something?") | Task 8.6 |
| Change receipts (AIActionResult) | `Action` struct + `AIActionResult` — UI rendering in follow-up |
| Week repair (downstream cascade check after skip/swap) | Counter note with `kind: plan_repair` — full automation in follow-up |
| Cook mode step compression | Post-MVP — recipe detail enhancement |
| Kitchen memory UI ("Things Tore has learned") | Post-MVP — settings page extension |
| Graceful degradation law | Spec section added — enforced by design not code |
| AI source of truth rule | Spec section added — enforced by architecture |

**Gaps carried forward (post-MVP):**
- **Undo toast UI**: The tier-1/2 undo chip in chat and toast on PubSub broadcast is not rendered yet. `Action.tier` is set correctly — add undo rendering in a follow-up task.
- **Draft acceptance flow**: Plan generation sets state but the "Accept draft" button in the week view is not wired to an event handler yet — follow-up task.
- **Slot states** (`flexible`, `draft`): added to spec but plan slots use string-keyed maps without explicit state enum — add in a follow-up migration.
- **Cook mode step compression**: Recipe detail enhancement, post-MVP.
- **Week repair automation**: Counter note with `plan_repair` kind is generated; full auto-repair of downstream slots is post-MVP.

**Type consistency:** `ChatHandler.handle_text/2` returns `{:ok, String.t(), Action.t() | nil}`. `PhotoPipeline.process/1` returns `{:ok, [result()]}`. `ReviewLive.mount/3` expects `%{"class" => ..., "id" => ...}` — matched by `"/review/:class/:id"`. `InsightsHandler.synthesise/0` returns `{:ok, [map()]}` — matched in tests and scheduler. `InsightsHandler.this_week_context/0` returns `String.t()`. `SystemPrompt.build/0` returns `String.t()`. `Family.replace_insights/1` takes `[map()]` and returns `{:ok, [FamilyInsights.t()]}`. Consistent.
