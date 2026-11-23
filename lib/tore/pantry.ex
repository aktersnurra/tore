defmodule Tore.Pantry do
  import Ecto.Query
  alias Tore.{Repo, Scope}
  alias Tore.Pantry.{Expiry, PantryItem}
  alias Tore.Recipes.Ingredient

  @doc """
  Upsert a single canonicalised pantry belief.

  Expects an attrs map with `catalogue_name`, optional `matched_key`, plus
  `quantity`, `unit`, optional `pack_size` (in `unit`), `category`, `default_unit`, `provenance`, `last_seen_at`,
  and optional `shelf_life_days` and `expires_on`. See `Tore.Pantry.Expiry`.
  Resolves the ingredient by key (find-or-create), then bumps an existing
  pantry row keyed on ingredient_id, or inserts a new one. The pantry row
  always shows the catalogue name — never the receipt's product variant.

  Returns `{:ok, item, :added | :bumped, before}`, where `before` is a bumped item's
  `before_image/1` and nil for an added one.
  """
  @spec upsert_belief(Scope.t(), map()) ::
          {:ok, PantryItem.t(), :added | :bumped, map() | nil} | {:error, term()}
  def upsert_belief(%Scope{} = scope, attrs) do
    Repo.transaction(fn ->
      ingredient = find_or_create_ingredient(scope, attrs)

      case Repo.get_by(PantryItem, [ingredient_id: ingredient.id], Scope.repo_opts(scope)) do
        nil ->
          attrs
          |> base_pantry_attrs(ingredient)
          |> Map.put(:quantity, attrs[:quantity])
          |> Map.merge(expiry_attrs(%{expires_at: nil, expires_source: nil}, attrs, ingredient))
          |> then(&add_item(scope, &1))
          |> kept(:added, nil)

        existing ->
          existing |> bump_existing(attrs, ingredient) |> kept(:bumped, before_image(existing))
      end
    end)
    |> case do
      {:ok, {item, :added, before}} ->
        # Something new in the pantry: Jev says how fast it goes, if nobody has asked yet.
        :ok = Tore.Pantry.Lasts.later(scope)
        {:ok, item, :added, before}

      {:ok, {item, change, before}} ->
        {:ok, item, change, before}

      {:error, _} = err ->
        err
    end
  end

  # A row the changeset refuses ends the write with why, for the run to fail on and log.
  defp kept({:ok, item}, change, before), do: {item, change, before}
  defp kept({:error, changeset}, _change, _before), do: Repo.rollback(changeset)

  defp expiry_attrs(current, attrs, ingredient) do
    {expires_at, expires_source} =
      Expiry.next(current, attrs, ingredient.shelf_life_days, Tore.Clock.today())

    %{expires_at: expires_at, expires_source: expires_source}
  end

  defp find_or_create_ingredient(scope, attrs) do
    key =
      case attrs[:matched_key] do
        k when is_binary(k) and k != "" -> k
        _ -> Ingredient.to_key(attrs[:catalogue_name] || attrs[:name] || "")
      end

    case Repo.get_by(Ingredient, [key: key], Scope.repo_opts(scope)) do
      nil ->
        %Ingredient{household_id: scope.household_id}
        |> Ingredient.changeset(%{
          name: attrs[:catalogue_name] || attrs[:name],
          key: key,
          category: attrs[:category],
          default_unit: attrs[:default_unit] || attrs[:unit],
          shelf_life_days: attrs[:shelf_life_days]
        })
        |> Repo.insert()
        |> case do
          {:ok, ingredient} -> ingredient
          {:error, changeset} -> Repo.rollback(changeset)
        end

      ing ->
        fill_shelf_life(ing, attrs[:shelf_life_days])
    end
  end

  # Only fills a gap, so a correction from the household is never overwritten.
  # `change/2` rather than the changeset, which would re-derive the key.
  defp fill_shelf_life(%Ingredient{shelf_life_days: nil} = ingredient, days)
       when is_integer(days),
       do: ingredient |> Ecto.Changeset.change(shelf_life_days: days) |> Repo.update!()

  defp fill_shelf_life(ingredient, _days), do: ingredient

  # Pantry row always shows the ingredient's catalogue name — receipt-specific
  # variants (brand, pack size, fat percentage) live on the cost ledger, not
  # in the pantry.
  defp base_pantry_attrs(attrs, ingredient) do
    %{
      name: ingredient.name,
      unit: attrs[:unit] || ingredient.default_unit,
      pack_size: attrs[:pack_size],
      category: attrs[:category] || ingredient.category,
      provenance: attrs[:provenance] || "manual",
      last_seen_at: attrs[:last_seen_at] || now(),
      ingredient_id: ingredient.id
    }
  end

  defp bump_existing(%PantryItem{} = item, attrs, ingredient) do
    {new_qty, new_unit} = next_quantity(item, attrs)

    next_provenance = attrs[:provenance] || item.provenance

    item
    |> PantryItem.changeset(
      %{
        quantity: new_qty,
        unit: new_unit,
        pack_size: pack_size(item, attrs),
        added_at: if(Expiry.bought?(attrs), do: Tore.Clock.today(), else: item.added_at),
        last_seen_at: attrs[:last_seen_at] || now(),
        provenance: next_provenance,
        belief: stronger_belief(item.belief, PantryItem.derive_belief(next_provenance))
      }
      |> Map.merge(expiry_attrs(item, attrs, ingredient))
    )
    |> Repo.update()
  end

  # A new pack's size, given in the row's unit; otherwise the size the row knows.
  defp pack_size(item, %{pack_size: %Decimal{} = size} = attrs) do
    if units_compatible?(item.unit, attrs[:unit]), do: size, else: item.pack_size
  end

  defp pack_size(item, _attrs), do: item.pack_size

  # A photo shows what's there now, so it replaces what we knew. Every other
  # source reports what came in, so it adds. A photo with no readable quantity
  # tells us nothing about the amount.
  defp next_quantity(item, %{provenance: "vision", quantity: quantity} = attrs)
       when not is_nil(quantity),
       do: {quantity, attrs[:unit] || item.unit}

  defp next_quantity(item, attrs),
    do: merge_quantity(item.quantity, item.unit, attrs[:quantity], attrs[:unit])

  # Sum only when units are compatible (equal, or one side nil). A conflict
  # (existing "L", incoming "ml") would silently turn 1 L into 501 L —
  # worse than refusing the new quantity. On conflict we keep the existing
  # quantity & unit; the *signal* (we saw this thing again) still updates
  # last_seen_at / provenance / belief upstream.
  defp merge_quantity(existing_qty, existing_unit, incoming_qty, incoming_unit) do
    case {Tore.Types.decimal(existing_qty), Tore.Types.decimal(incoming_qty)} do
      {nil, q} ->
        {q, existing_unit || incoming_unit}

      {q, nil} ->
        {q, existing_unit || incoming_unit}

      {a, b} ->
        if units_compatible?(existing_unit, incoming_unit) do
          {Decimal.add(a, b), existing_unit || incoming_unit}
        else
          {existing_qty, existing_unit}
        end
    end
  end

  defp units_compatible?(nil, _), do: true
  defp units_compatible?(_, nil), do: true
  defp units_compatible?(a, b), do: String.downcase(a) == String.downcase(b)

  # Belief on bump never weakens: a confirmed row stays confirmed even when
  # a weaker signal (receipt → :probable) bumps the quantity.
  @belief_strength %{"missing" => 0, "uncertain" => 1, "probable" => 2, "confirmed" => 3}
  defp stronger_belief(a, b) do
    if Map.get(@belief_strength, b, 0) >= Map.get(@belief_strength, a, 0), do: b, else: a
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Taken as always in the house: nobody keeps a pantry row for them.
  @always_at_home MapSet.new(
                    ~w(vatten water salt peppar svartpeppar vitpeppar pepper black_pepper),
                    &Ingredient.to_key/1
                  )

  @typedoc "Something at home Tore is unsure is still there: as the dish names it, and its row."
  @type unsure :: %{name: String.t(), id: integer(), last_seen_at: DateTime.t() | nil}

  @doc """
  `names` (a dish's ingredients) split into what the pantry holds and what's missing, each in the
  order given, and which of what it holds Tore is unsure of (`unsure`, also in `have`). Matched
  exactly by ingredient key, as the shopping list is, so a near miss counts as missing rather
  than as had.
  """
  @spec at_home(Scope.t(), [String.t()]) :: %{
          have: [String.t()],
          missing: [String.t()],
          unsure: [unsure()]
        }
  def at_home(%Scope{} = scope, names) do
    now = DateTime.utc_now()
    today = Tore.Clock.today()
    held = scope |> list_usable() |> Map.new(&{Ingredient.to_key(&1.name), &1})
    {have, missing} = Enum.split_with(names, &at_home?(held, Ingredient.to_key(&1)))

    unsure =
      for name <- have,
          %PantryItem{} = item <- [held[Ingredient.to_key(name)]],
          PantryItem.effective_belief(item, now, today) == :uncertain,
          do: %{name: name, id: item.id, last_seen_at: item.last_seen_at}

    %{have: have, missing: missing, unsure: unsure}
  end

  defp at_home?(held, key), do: Map.has_key?(held, key) or MapSet.member?(@always_at_home, key)

  @spec add_item(Scope.t(), map()) :: {:ok, PantryItem.t()} | {:error, Ecto.Changeset.t()}
  def add_item(%Scope{} = scope, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:added_at, Tore.Clock.today())
      |> Map.put_new(:provenance, "manual")
      |> Map.put_new(:last_seen_at, now)

    attrs = Map.put_new(attrs, :belief, PantryItem.derive_belief(attrs[:provenance]))

    %PantryItem{household_id: scope.household_id} |> PantryItem.changeset(attrs) |> Repo.insert()
  end

  @spec remove_item(Scope.t(), integer()) :: :ok | {:error, :not_found}
  @before_fields ~w(name ingredient_id quantity unit pack_size category added_at expires_at expires_source provenance belief last_seen_at)a

  @doc "An item as `Tore.Harness.Undo` stores it, so a run can put it back."
  @spec before_image(PantryItem.t()) :: Tore.Harness.Undo.pantry_before()
  def before_image(%PantryItem{} = item), do: Map.take(item, @before_fields)

  @doc """
  Puts an item back as `before_image/1` found it, or removes it if the run created it
  (`:absent`). An item since removed comes back with its id; one already gone stays gone. An item
  that someone has since added again under a new id is left as they added it, since one
  ingredient has one pantry row.
  """
  @spec restore_item(Scope.t(), integer(), Tore.Harness.Undo.pantry_before() | :absent) :: :ok
  def restore_item(%Scope{} = scope, item_id, :absent) do
    _ = remove_item(scope, item_id)
    :ok
  end

  def restore_item(%Scope{} = scope, item_id, before) do
    case Repo.get(PantryItem, item_id, Scope.repo_opts(scope)) do
      nil ->
        %PantryItem{id: item_id, household_id: scope.household_id}
        |> Ecto.Changeset.change(before)
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:household_id, :ingredient_id])

      item ->
        item |> Ecto.Changeset.change(before) |> Repo.update!()
    end

    :ok
  end

  def remove_item(%Scope{} = scope, item_id) do
    case Repo.get(PantryItem, item_id, Scope.repo_opts(scope)) do
      nil -> {:error, :not_found}
      item -> Repo.delete(item) |> then(fn _ -> :ok end)
    end
  end

  @doc """
  Set or clear an item's expiry date by hand. The date stays until the item is
  bought again, and the days since it came in become the ingredient's shelf
  life, so the next guess is better.
  """
  @spec set_expiry(Scope.t(), integer(), Date.t() | nil) ::
          {:ok, PantryItem.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_expiry(%Scope{} = scope, item_id, expires_at) do
    case Repo.get(PantryItem, item_id, Scope.repo_opts(scope)) do
      nil ->
        {:error, :not_found}

      item ->
        Repo.transaction(fn ->
          learn_shelf_life(scope, item, expires_at)

          item
          |> PantryItem.changeset(%{
            expires_at: expires_at,
            expires_source: expires_at && "manual"
          })
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
    end
  end

  defp learn_shelf_life(scope, %PantryItem{ingredient_id: id} = item, %Date{} = expires_at)
       when not is_nil(id) do
    case Expiry.parse_shelf_life(Date.diff(expires_at, item.added_at)) do
      nil ->
        :ok

      days ->
        Ingredient
        |> Repo.get!(id, Scope.repo_opts(scope))
        |> Ecto.Changeset.change(shelf_life_days: days)
        |> Repo.update!()
    end
  end

  defp learn_shelf_life(_scope, _item, _expires_at), do: :ok

  @doc """
  What's in the pantry and still within its date, if it has one. A row believed missing (used up
  in a dinner, `use_up/2`, or likely eaten by now) isn't, until it's bought or seen again.
  """
  @spec list_usable(Scope.t()) :: [PantryItem.t()]
  def list_usable(%Scope{} = scope) do
    now = DateTime.utc_now()
    today = Tore.Clock.today()

    Enum.reject(
      list_inventory(scope),
      &(PantryItem.past_date?(&1, today) or
          PantryItem.effective_belief(&1, now, today) == :missing)
    )
  end

  # What outlasts one dinner: the flour, the spices, the soy sauce.
  @lasts ~w(dry_goods herbs_spices condiments)

  @typedoc "An ingredient a dinner took, with how much when the recipe says."
  @type use :: %{name: String.t(), quantity: Decimal.t() | nil, unit: String.t() | nil}

  @typedoc "What `use_up/2` changed, so `put_back/2` can undo it; `gone` when it ran out."
  @type used :: %{
          id: integer(),
          name: String.t(),
          belief: String.t(),
          last_seen_at: DateTime.t(),
          quantity: Decimal.t() | nil,
          gone: boolean()
        }

  @doc """
  A dinner was cooked with `uses`. Where the pantry's amount and the dinner's are in units of the
  same kind (`Tore.Prices.Units`: weights, volumes or counts), the dinner's is taken off, and what
  it ran out of is believed missing. Otherwise what the pantry held is believed missing, except
  what outlasts a dinner (dry goods, spices, condiments). Buying it again brings it back, as any
  stronger belief does. Returns what changed, for `put_back/2`.
  """
  @spec use_up(Scope.t(), [use()]) :: [used()]
  def use_up(%Scope{} = scope, uses) do
    wanted = Map.new(uses, &{Ingredient.to_key(&1.name), &1})
    now = now()

    scope
    |> list_usable()
    |> Repo.preload(:ingredient)
    |> Enum.flat_map(fn item ->
      case Map.fetch(wanted, Ingredient.to_key(item.name)) do
        {:ok, use} -> take(scope, item, left(item, use), now)
        :error -> []
      end
    end)
  end

  defp take(_scope, _item, :lasts, _now), do: []

  defp take(scope, item, left, now) do
    set =
      case left do
        {:left, quantity} -> [quantity: quantity, last_seen_at: now]
        :gone -> [belief: "missing", last_seen_at: now]
      end

    Repo.update_all(
      from(p in PantryItem, where: p.id == ^item.id),
      [set: set],
      Scope.repo_opts(scope)
    )

    [
      item
      |> Map.take([:id, :name, :belief, :last_seen_at, :quantity])
      |> Map.put(:gone, left == :gone)
    ]
  end

  # What's left of `item` once `use` is taken, in the item's own unit.
  defp left(%PantryItem{quantity: %Decimal{} = have} = item, %{quantity: %Decimal{} = need} = use) do
    with {have, base} <- Tore.Prices.Units.to_base(have, item.unit),
         {need, ^base} <- Tore.Prices.Units.to_base(need, use.unit) do
      remaining = Decimal.sub(have, need)

      if Decimal.compare(remaining, 0) == :gt do
        {per_unit, _base} = Tore.Prices.Units.to_base(Decimal.new(1), item.unit)
        {:left, remaining |> Decimal.div(per_unit) |> Decimal.round(3) |> Decimal.normalize()}
      else
        :gone
      end
    else
      _not_comparable -> whole(item)
    end
  end

  defp left(item, _use), do: whole(item)

  defp whole(item), do: if(lasts?(item), do: :lasts, else: :gone)

  defp lasts?(%PantryItem{ingredient: %Ingredient{category: category}}), do: category in @lasts
  defp lasts?(_item), do: false

  @doc "Undoes `use_up/2`: each row's belief and amount as they were."
  @spec put_back(Scope.t(), [used()]) :: :ok
  def put_back(%Scope{} = scope, used) do
    for %{id: id, belief: belief, last_seen_at: seen} = row <- used do
      Repo.update_all(
        from(p in PantryItem, where: p.id == ^id),
        [set: [belief: belief, last_seen_at: seen, quantity: row[:quantity]]],
        Scope.repo_opts(scope)
      )
    end

    :ok
  end

  @doc """
  Something put away by hand on Hemma, as written ("2 l mjölk" read by `Tore.Shop.parse_line/1`):
  sure now, added to its ingredient's row if there is one (a row used up comes back). A name
  Tore hasn't learned yet, new or known without a section (one a recipe brought), is learned in
  the background, so it finds its group.
  """
  @spec put_away(Scope.t(), String.t(), Decimal.t() | nil, String.t() | nil) ::
          {:ok, PantryItem.t()} | {:error, term()}
  def put_away(%Scope{} = scope, name, quantity, unit) do
    matched_key =
      case Tore.Pantry.Match.ingredient(scope, {:name, name}) do
        {:ok, ingredient} -> ingredient.key
        :unknown -> nil
      end

    attrs = %{
      catalogue_name: name,
      matched_key: matched_key,
      quantity: quantity,
      unit: unit,
      provenance: "manual",
      last_seen_at: now()
    }

    with {:ok, item, _change, _before} <- upsert_belief(scope, attrs) do
      # Learning skips what has its section already, so a learned name costs nothing.
      :ok = Tore.Pantry.Learn.later(scope, [name])
      {:ok, item}
    end
  end

  @doc """
  Still there: seen now, so it's sure again. A date it has outlived goes, since the household
  says it's fine; nothing is learned from that.
  """
  @spec confirm_item(Scope.t(), integer()) :: {:ok, PantryItem.t()} | {:error, :not_found}
  def confirm_item(%Scope{} = scope, item_id) do
    with {:ok, item} <- fetch_item(scope, item_id) do
      outlived = PantryItem.past_date?(item, Tore.Clock.today())

      item
      |> Ecto.Changeset.change(
        Map.merge(
          %{belief: "confirmed", last_seen_at: now()},
          if(outlived, do: %{expires_at: nil, expires_source: nil}, else: %{})
        )
      )
      |> Repo.update()
    end
  end

  @doc "The pantry's row for `name`, whatever Tore believes of it; nil when it has none."
  @spec get_by_name(Scope.t(), String.t()) :: PantryItem.t() | nil
  def get_by_name(%Scope{} = scope, name) do
    case Tore.Pantry.Match.ingredient(scope, {:name, name}) do
      {:ok, %Ingredient{id: id}} ->
        Repo.get_by(PantryItem, [ingredient_id: id], Scope.repo_opts(scope))

      :unknown ->
        nil
    end
  end

  @doc "Gone: believed missing, as after a dinner (`use_up/2`), until it's bought again."
  @spec mark_gone(Scope.t(), integer()) :: {:ok, PantryItem.t()} | {:error, :not_found}
  def mark_gone(%Scope{} = scope, item_id) do
    with {:ok, item} <- fetch_item(scope, item_id) do
      :ok = learn_lasted(scope, item)
      item |> Ecto.Changeset.change(belief: "missing", last_seen_at: now()) |> Repo.update()
    end
  end

  # Gone: how long the pack lasted teaches how fast it goes, for what's eaten between meals. A
  # regular buy's rhythm moves halfway to it (so it's also on the list sooner or later); anything
  # else with a half-life learns its own days. What's only for cooking learns nothing, and so does
  # a row Tore had stopped believing in (a half-life or more since it was seen): then it lasted at
  # most that long, which would only ever slow the rhythm down.
  defp learn_lasted(_scope, %PantryItem{belief: "missing"}), do: :ok
  defp learn_lasted(_scope, %PantryItem{added_at: nil}), do: :ok
  defp learn_lasted(_scope, %PantryItem{ingredient_id: nil}), do: :ok

  defp learn_lasted(scope, %PantryItem{} = item) do
    opts = Scope.repo_opts(scope)
    today = Tore.Clock.today()
    lasted = max(Date.diff(today, item.added_at), 1)

    unseen =
      if item.last_seen_at, do: Date.diff(today, DateTime.to_date(item.last_seen_at)), else: 0

    basic =
      Repo.one(
        from(b in Tore.Basics.Basic,
          where: b.ingredient_id == ^item.ingredient_id and not b.stopped
        ),
        opts
      )

    if basic do
      if unseen < basic.interval_days do
        basic
        |> Ecto.Changeset.change(interval_days: halfway(basic.interval_days, lasted))
        |> Repo.update!()
      end
    else
      ingredient = Repo.get!(Ingredient, item.ingredient_id, opts)
      days = ingredient.lasts_days || Tore.Pantry.Lasts.half_life_days(ingredient.lasts)

      if days && unseen < days do
        ingredient |> Ecto.Changeset.change(lasts_days: halfway(days, lasted)) |> Repo.update!()
      end
    end

    :ok
  end

  defp halfway(days, lasted), do: max(round((days + lasted) / 2), 1)

  @doc """
  What's left of it, said by the household (some used without cooking through Tore): sure now,
  in the unit given, or its own when none is. Nothing left is gone.
  """
  @spec set_left(Scope.t(), integer(), Decimal.t(), String.t() | nil) ::
          {:ok, PantryItem.t()} | {:error, :not_found}
  def set_left(%Scope{} = scope, item_id, %Decimal{} = quantity, unit) do
    if Decimal.compare(quantity, 0) == :gt do
      with {:ok, item} <- fetch_item(scope, item_id) do
        item
        |> Ecto.Changeset.change(
          quantity: quantity,
          unit: unit || item.unit,
          belief: "confirmed",
          last_seen_at: now()
        )
        |> Repo.update()
      end
    else
      mark_gone(scope, item_id)
    end
  end

  defp fetch_item(scope, item_id) do
    case Repo.get(PantryItem, item_id, Scope.repo_opts(scope)) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  @doc "Where Hemma hears that what's kept changed in the background (`changed/1`)."
  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{household_id: id}), do: "pantry:household:#{id}"

  @doc """
  Says what's kept changed in the background: a section learned, or Jev's answers kept. Hemma
  loads again.
  """
  @spec changed(Scope.t()) :: :ok
  def changed(%Scope{} = scope),
    do: Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), :pantry_changed)

  @doc "Everything kept, with its ingredient, which says where it belongs once learned."
  @spec list_kept(Scope.t()) :: [PantryItem.t()]
  def list_kept(%Scope{} = scope), do: scope |> list_inventory() |> Repo.preload(:ingredient)

  @doc """
  The names of what's kept that has no section yet (a name a recipe brought, never learned), so
  it sits in the cupboard until it's learned (`Tore.Pantry.Learn`).
  """
  @spec without_section(Scope.t()) :: [String.t()]
  def without_section(%Scope{} = scope) do
    for item <- list_kept(scope),
        item.ingredient == nil or item.ingredient.category == nil,
        do: item.name
  end

  @doc """
  Everything kept, each with its half-life when it's eaten between meals: the household's own
  rhythm when Basics has learned one, then the days it's been seen to last (`mark_gone/2`),
  otherwise Jev's guess (`Tore.Pantry.Lasts`).
  """
  @spec list_inventory(Scope.t()) :: [PantryItem.t()]
  def list_inventory(%Scope{} = scope) do
    from(p in PantryItem,
      left_join: i in Ingredient,
      on: i.id == p.ingredient_id,
      left_join: b in Tore.Basics.Basic,
      on:
        b.ingredient_id == p.ingredient_id and b.household_id == p.household_id and not b.stopped,
      order_by: p.name,
      select: {p, b.interval_days, i.lasts_days, i.lasts}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.map(fn {item, rhythm, seen, lasts} ->
      %{item | half_life_days: rhythm || seen || Tore.Pantry.Lasts.half_life_days(lasts)}
    end)
  end

  @doc """
  Resolve a free-text name to a single pantry item by case-insensitive
  bidirectional substring match. Returns the item if exactly one row
  matches, otherwise `{:ambiguous, candidates}` or `{:error, :not_found}`.

  Used by the agent's tool path so "we're out of milk" can find the
  pantry row without the agent needing to know item ids.
  """
  @spec find_by_name_fuzzy(Scope.t(), String.t()) ::
          {:ok, PantryItem.t()} | {:ambiguous, [PantryItem.t()]} | {:error, :not_found}
  def find_by_name_fuzzy(%Scope{} = scope, query) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    if needle == "" do
      {:error, :not_found}
    else
      matches =
        list_inventory(scope)
        |> Enum.filter(fn item ->
          name = String.downcase(item.name)
          String.contains?(name, needle) or String.contains?(needle, name)
        end)

      case matches do
        [] -> {:error, :not_found}
        [one] -> {:ok, one}
        many -> {:ambiguous, many}
      end
    end
  end

  # Confidence order: most-certain bucket first, missing items last.
  # docs/specs/ui.md §16.5 — pantry rows render as belief, not category.
  @belief_order ~w[confirmed probable uncertain missing]a

  @spec list_inventory_by_belief(Scope.t()) :: [{atom(), [PantryItem.t()]}]
  def list_inventory_by_belief(%Scope{} = scope) do
    now = DateTime.utc_now()
    today = Tore.Clock.today()
    items = list_inventory(scope)
    grouped = Enum.group_by(items, &PantryItem.effective_belief(&1, now, today))

    @belief_order
    |> Enum.flat_map(fn key ->
      case Map.get(grouped, key) do
        nil -> []
        bucket -> [{key, bucket}]
      end
    end)
  end
end
