# Phase 1 — Family Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace singleton Household with a Family tenant model as the foundation for all future phases.

**Architecture:** Add `families` table, migrate `household_preferences` to include `family_id`, add `family_id` to `users`, create `Tore.Family` context as a drop-in replacement for `Tore.Household`, update all call sites. Singleton behavior preserved — `get_family!/0` auto-creates a default family if none exists.

**Tech Stack:** Elixir/Phoenix/LiveView, SQLite/Ecto, jj version control

---

## Task 1 — `families` table + `FamilySchema` + basic `Tore.Family` context

**Files touched:**
- `priv/repo/migrations/20260529000001_create_families.exs` (new)
- `lib/tore/family/family_schema.ex` (new)
- `lib/tore/family.ex` (new, partial — preferences functions added in Task 2)
- `test/tore/family_test.exs` (new)

### Steps

- [ ] Write `test/tore/family_test.exs` (test first)
- [ ] Run `mix test test/tore/family_test.exs` — confirm it fails (module not found)
- [ ] Create migration `priv/repo/migrations/20260529000001_create_families.exs`
- [ ] Create schema `lib/tore/family/family_schema.ex`
- [ ] Create context `lib/tore/family.ex` (Task 1 portion)
- [ ] Run `mix ecto.migrate`
- [ ] Run `mix test test/tore/family_test.exs` — confirm all 4 tests pass
- [ ] Commit: `jj describe -m "feat(family): add families table, FamilySchema, and basic Family context"`

### Code

**`test/tore/family_test.exs`**

```elixir
defmodule Tore.FamilyTest do
  use Tore.DataCase, async: true
  alias Tore.Family

  test "get_family!/0 creates default family when none exists" do
    family = Family.get_family!()
    assert family.name == "Home"
    assert family.locale == "sv"
  end

  test "get_family!/0 returns existing family on second call" do
    f1 = Family.get_family!()
    f2 = Family.get_family!()
    assert f1.id == f2.id
  end

  test "create_family/1 inserts a family" do
    assert {:ok, family} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    assert family.name == "Rydholm"
  end

  test "create_family/1 rejects invalid locale" do
    assert {:error, cs} = Family.create_family(%{name: "Test", locale: "zz"})
    assert cs.errors[:locale]
  end
end
```

**`priv/repo/migrations/20260529000001_create_families.exs`**

```elixir
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

**`lib/tore/family/family_schema.ex`**

```elixir
defmodule Tore.Family.FamilySchema do
  use Ecto.Schema
  import Ecto.Changeset

  schema "families" do
    field :name, :string
    field :locale, :string, default: "sv"
    has_many :users, Tore.Accounts.User
    has_one :preferences, Tore.Family.Preferences
    timestamps()
  end

  def changeset(family, attrs) do
    family
    |> cast(attrs, [:name, :locale])
    |> validate_required([:name, :locale])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:locale, ~w(sv en))
  end
end
```

**`lib/tore/family.ex`** (Task 1 portion — preferences functions added in Task 2)

```elixir
defmodule Tore.Family do
  import Ecto.Query
  alias Tore.{Repo, Family.FamilySchema}

  @spec get_family!() :: FamilySchema.t()
  def get_family! do
    case Repo.one(FamilySchema) do
      nil ->
        %FamilySchema{}
        |> FamilySchema.changeset(%{name: "Home", locale: "sv"})
        |> Repo.insert!()

      family ->
        family
    end
  end

  @spec create_family(map()) :: {:ok, FamilySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_family(attrs) do
    %FamilySchema{}
    |> FamilySchema.changeset(attrs)
    |> Repo.insert()
  end
end
```

---

## Task 2 — Migrate `household_preferences` + `Tore.Family.Preferences` schema + preferences functions

**Files touched:**
- `priv/repo/migrations/20260529000002_add_family_id_to_household_preferences.exs` (new)
- `lib/tore/family/preferences.ex` (new — replaces `lib/tore/household/preferences.ex`)
- `lib/tore/family.ex` (extend with preferences functions)
- `test/tore/family_test.exs` (extend with preferences tests)

### Steps

- [ ] Add preferences tests to `test/tore/family_test.exs`
- [ ] Run `mix test test/tore/family_test.exs` — confirm new tests fail (no preferences functions yet)
- [ ] Create migration `priv/repo/migrations/20260529000002_add_family_id_to_household_preferences.exs`
- [ ] Create `lib/tore/family/preferences.ex`
- [ ] Extend `lib/tore/family.ex` with preferences functions
- [ ] Run `mix ecto.migrate`
- [ ] Run `mix test test/tore/family_test.exs` — confirm all tests pass
- [ ] Commit: `jj describe -m "feat(family): add family_id to household_preferences, Family.Preferences schema, and preferences functions"`

### Code

**Additional tests to append to `test/tore/family_test.exs`**

```elixir
  describe "preferences" do
    test "get_preferences/0 returns empty preferences struct when none exist" do
      prefs = Family.get_preferences()
      assert prefs.default_portions == 4
      assert prefs.dietary_restrictions == []
    end

    test "update_preferences/1 persists and returns updated preferences" do
      assert {:ok, prefs} = Family.update_preferences(%{default_portions: 6, dietary_restrictions: ["vegan"]})
      assert prefs.default_portions == 6
      assert prefs.dietary_restrictions == ["vegan"]
    end

    test "update_preferences/1 is idempotent — second update replaces first" do
      {:ok, _} = Family.update_preferences(%{default_portions: 6})
      assert {:ok, prefs} = Family.update_preferences(%{default_portions: 2})
      assert prefs.default_portions == 2
    end

    test "prefs_to_dietary_guidance/1 returns nil for empty prefs" do
      prefs = Family.get_preferences()
      assert Family.prefs_to_dietary_guidance(prefs) == nil
    end

    test "prefs_to_dietary_guidance/1 formats dietary restrictions" do
      {:ok, prefs} = Family.update_preferences(%{dietary_restrictions: ["vegetarian"], allergies: ["nuts"]})
      guidance = Family.prefs_to_dietary_guidance(prefs)
      assert guidance =~ "Diet: vegetarian"
      assert guidance =~ "Allergies/hard avoids: nuts"
    end
  end
```

**`priv/repo/migrations/20260529000002_add_family_id_to_household_preferences.exs`**

```elixir
defmodule Tore.Repo.Migrations.AddFamilyIdToHouseholdPreferences do
  use Ecto.Migration

  def change do
    alter table(:household_preferences) do
      add :family_id, references(:families, on_delete: :delete_all)
    end
  end
end
```

**`lib/tore/family/preferences.ex`**

```elixir
defmodule Tore.Family.Preferences do
  use Ecto.Schema
  import Ecto.Changeset

  schema "household_preferences" do
    field :dietary_restrictions, {:array, :string}, default: []
    field :allergies, {:array, :string}, default: []
    field :dislikes, {:array, :string}, default: []
    field :cooking_style, {:array, :string}, default: []
    field :cuisine_preferences, :map, default: %{}
    field :default_portions, :integer, default: 4
    field :default_leftover_portions, :integer, default: 2
    field :include_lunches, :boolean, default: false
    field :planning_days, :integer, default: 5
    belongs_to :family, Tore.Family.FamilySchema
    timestamps()
  end

  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, [
      :dietary_restrictions,
      :allergies,
      :dislikes,
      :cooking_style,
      :cuisine_preferences,
      :default_portions,
      :default_leftover_portions,
      :include_lunches,
      :planning_days,
      :family_id
    ])
    |> validate_number(:default_portions, greater_than: 0)
    |> validate_number(:default_leftover_portions, greater_than_or_equal_to: 0)
    |> validate_inclusion(:planning_days, [5, 7])
  end
end
```

**`lib/tore/family.ex`** (complete file — Task 1 + Task 2 functions)

```elixir
defmodule Tore.Family do
  import Ecto.Query
  alias Tore.{Repo, Family.FamilySchema, Family.Preferences}

  @spec get_family!() :: FamilySchema.t()
  def get_family! do
    case Repo.one(FamilySchema) do
      nil ->
        %FamilySchema{}
        |> FamilySchema.changeset(%{name: "Home", locale: "sv"})
        |> Repo.insert!()

      family ->
        family
    end
  end

  @spec create_family(map()) :: {:ok, FamilySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_family(attrs) do
    %FamilySchema{}
    |> FamilySchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_preferences() :: Preferences.t()
  def get_preferences do
    family = get_family!()

    case Repo.get_by(Preferences, family_id: family.id) do
      nil -> %Preferences{family_id: family.id}
      prefs -> prefs
    end
  end

  @spec update_preferences(map()) :: {:ok, Preferences.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(attrs) do
    family = get_family!()

    case Repo.get_by(Preferences, family_id: family.id) do
      nil -> %Preferences{family_id: family.id}
      existing -> existing
    end
    |> Preferences.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec prefs_to_dietary_guidance(Preferences.t()) :: String.t() | nil
  def prefs_to_dietary_guidance(%Preferences{} = p) do
    parts =
      [
        restrictions_line(p.dietary_restrictions),
        allergies_line(p.allergies),
        dislikes_line(p.dislikes),
        style_line(p.cooking_style),
        cuisine_line(p.cuisine_preferences)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, "; ")
  end

  defp restrictions_line(nil), do: nil
  defp restrictions_line([]), do: nil
  defp restrictions_line(list), do: "Diet: #{Enum.join(list, ", ")}"

  defp allergies_line(nil), do: nil
  defp allergies_line([]), do: nil
  defp allergies_line(list), do: "Allergies/hard avoids: #{Enum.join(list, ", ")}"

  defp dislikes_line(nil), do: nil
  defp dislikes_line([]), do: nil
  defp dislikes_line(list), do: "Avoid too often: #{Enum.join(list, ", ")}"

  defp style_line(nil), do: nil
  defp style_line([]), do: nil
  defp style_line(list), do: "Cooking style: #{Enum.join(list, ", ")}"

  defp cuisine_line(nil), do: nil
  defp cuisine_line(map) when map == %{}, do: nil

  defp cuisine_line(map) do
    more = map |> Enum.filter(fn {_, v} -> v == "more" end) |> Enum.map(&elem(&1, 0))
    less = map |> Enum.filter(fn {_, v} -> v == "less" end) |> Enum.map(&elem(&1, 0))

    [
      if(more != [], do: "More of: #{Enum.join(more, ", ")}"),
      if(less != [], do: "Less of: #{Enum.join(less, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> "Cuisine: #{Enum.join(parts, "; ")}"
    end
  end
end
```

---

## Task 3 — Add `family_id` to `users` table + update `User` schema

**Files touched:**
- `priv/repo/migrations/20260529000003_add_family_id_to_users.exs` (new)
- `lib/tore/accounts/user.ex` (add `belongs_to :family`)

### Steps

- [ ] Create migration `priv/repo/migrations/20260529000003_add_family_id_to_users.exs`

  > Note: The migration `up` must first ensure a family row exists. It uses a raw SQL `INSERT OR IGNORE` so the `execute` in the same migration can safely `SELECT id FROM families LIMIT 1`. The families migration (Task 1) must have already run.

- [ ] Update `lib/tore/accounts/user.ex` to add `belongs_to :family`
- [ ] Run `mix ecto.migrate`
- [ ] Run `mix test` — existing test suite passes without changes
- [ ] Commit: `jj describe -m "feat(family): add family_id to users table and User schema"`

### Code

**`priv/repo/migrations/20260529000003_add_family_id_to_users.exs`**

```elixir
defmodule Tore.Repo.Migrations.AddFamilyIdToUsers do
  use Ecto.Migration

  def up do
    # Ensure at least one family exists so the UPDATE below has a target
    execute """
    INSERT INTO families (name, locale, inserted_at, updated_at)
    SELECT 'Home', 'sv', datetime('now'), datetime('now')
    WHERE NOT EXISTS (SELECT 1 FROM families)
    """

    alter table(:users) do
      add :family_id, references(:families, on_delete: :nilify_all)
    end

    execute """
    UPDATE users SET family_id = (SELECT id FROM families LIMIT 1)
    WHERE family_id IS NULL
    """
  end

  def down do
    alter table(:users) do
      remove :family_id
    end
  end
end
```

**`lib/tore/accounts/user.ex`** (complete file)

```elixir
defmodule Tore.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :account_code_hash, :string
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :preferences, :map, default: %{}
    field :locale, :string, default: "sv"
    belongs_to :family, Tore.Family.FamilySchema
    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :role, :account_code_hash])
    |> validate_required([:name, :role, :account_code_hash])
    |> validate_length(:name, min: 1, max: 100)
  end

  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:preferences])
    |> validate_required([:preferences])
  end
end
```

---

## Task 4 — Replace `Tore.Household` call sites + make `Household` a delegation shim

**Files touched:**
- `lib/tore_web/live/prep_live.ex`
- `lib/tore_web/live/cooking_live.ex`
- `lib/tore_web/live/planner_live.ex`
- `lib/tore/household.ex` (replaced with delegation shim)

### Steps

- [ ] Update `lib/tore_web/live/prep_live.ex` — replace `Tore.Household` with `Tore.Family`
- [ ] Update `lib/tore_web/live/cooking_live.ex` — replace `alias Tore.Household` with `alias Tore.Family`, update all call sites
- [ ] Update `lib/tore_web/live/planner_live.ex` — replace `Tore.Household` with `Tore.Family`
- [ ] Replace `lib/tore/household.ex` with the delegation shim below
- [ ] Run `mix test` — full suite passes
- [ ] Commit: `jj describe -m "feat(family): replace Household call sites with Family, keep Household as deprecated shim"`

### Code

**`lib/tore_web/live/prep_live.ex`** — change line 17:

```elixir
# Before:
guidance = Tore.Household.get_preferences() |> Tore.Household.prefs_to_dietary_guidance()

# After:
guidance = Tore.Family.get_preferences() |> Tore.Family.prefs_to_dietary_guidance()
```

**`lib/tore_web/live/cooking_live.ex`** — change alias and call sites:

```elixir
# Before:
alias Tore.Household
# ...
prefs = Household.get_preferences()
# ...
case Household.update_preferences(full_attrs) do

# After:
alias Tore.Family
# ...
prefs = Family.get_preferences()
# ...
case Family.update_preferences(full_attrs) do
```

**`lib/tore_web/live/planner_live.ex`** — change lines 75 and 161:

```elixir
# Before (both occurrences):
Tore.Household.get_preferences() |> Tore.Household.prefs_to_dietary_guidance()

# After (both occurrences):
Tore.Family.get_preferences() |> Tore.Family.prefs_to_dietary_guidance()
```

**`lib/tore/household.ex`** (complete replacement — delegation shim):

```elixir
defmodule Tore.Household do
  @moduledoc """
  Deprecated. Use `Tore.Family` instead.
  This module is kept as a compatibility shim for one release cycle.
  """

  @deprecated "Use Tore.Family.get_preferences/0 instead"
  defdelegate get_preferences(), to: Tore.Family

  @deprecated "Use Tore.Family.update_preferences/1 instead"
  defdelegate update_preferences(attrs), to: Tore.Family

  @deprecated "Use Tore.Family.prefs_to_dietary_guidance/1 instead"
  defdelegate prefs_to_dietary_guidance(prefs), to: Tore.Family
end
```

---

## Completion checklist

- [ ] Task 1 complete and committed
- [ ] Task 2 complete and committed
- [ ] Task 3 complete and committed
- [ ] Task 4 complete and committed
- [ ] `mix test` passes in full
- [ ] `mix compile --warnings-as-errors` passes (no unused alias warnings)
- [ ] `lib/tore/household/preferences.ex` can be deleted once `Tore.Household.Preferences` is no longer referenced anywhere (verify with `grep -r "Household.Preferences" lib/`)

## Notes

- `get_family!/0` uses `Repo.one/1` which returns `nil` or raises on multiple rows. With a singleton family this is safe. When multi-tenancy is introduced later, callers will pass an explicit `family_id` and this auto-create behavior will be scoped out.
- The `household_preferences` table is intentionally not renamed in Phase 1. A follow-up migration can rename it to `family_preferences` once all consumers are updated — keeping Phase 1 surgical.
- Task 3's migration uses `INSERT OR IGNORE`-style SQL (SQLite `INSERT ... WHERE NOT EXISTS`) rather than calling `get_family!/0` from Elixir, keeping the migration self-contained.
