defmodule Tore.Pantry do
  import Ecto.Query
  require Logger
  alias Tore.{Repo, Scope}
  alias Tore.Pantry.{Expiry, PantryItem}
  alias Tore.Recipes.Ingredient

  @doc """
  Upsert a single canonicalised pantry belief.

  Expects an attrs map with `catalogue_name`, optional `matched_key`, plus
  `quantity`, `unit`, `category`, `default_unit`, `provenance`, `last_seen_at`,
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
          {:ok, item} =
            attrs
            |> base_pantry_attrs(ingredient)
            |> Map.put(:quantity, attrs[:quantity])
            |> Map.merge(expiry_attrs(%{expires_at: nil, expires_source: nil}, attrs, ingredient))
            |> then(&add_item(scope, &1))

          {item, :added, nil}

        existing ->
          before = before_image(existing)
          {:ok, item} = bump_existing(existing, attrs, ingredient)
          {item, :bumped, before}
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
        {:ok, ing} =
          %Ingredient{household_id: scope.household_id}
          |> Ingredient.changeset(%{
            name: attrs[:catalogue_name] || attrs[:name],
            key: key,
            category: attrs[:category],
            default_unit: attrs[:default_unit] || attrs[:unit],
            shelf_life_days: attrs[:shelf_life_days]
          })
          |> Repo.insert()

        ing

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
        added_at: if(Expiry.bought?(attrs), do: Tore.Clock.today(), else: item.added_at),
        last_seen_at: attrs[:last_seen_at] || now(),
        provenance: next_provenance,
        belief: stronger_belief(item.belief, PantryItem.derive_belief(next_provenance))
      }
      |> Map.merge(expiry_attrs(item, attrs, ingredient))
    )
    |> Repo.update()
  end

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

  @doc """
  `names` (a dish's ingredients) split into what the pantry holds and what's missing, each in the
  order given. Matched exactly by ingredient key, as the shopping list is, so a near miss counts
  as missing rather than as had.
  """
  @spec at_home(Scope.t(), [String.t()]) :: %{have: [String.t()], missing: [String.t()]}
  def at_home(%Scope{} = scope, names) do
    held = scope |> list_usable() |> MapSet.new(&Ingredient.to_key(&1.name))
    {have, missing} = Enum.split_with(names, &at_home?(held, Ingredient.to_key(&1)))
    %{have: have, missing: missing}
  end

  defp at_home?(held, key), do: MapSet.member?(held, key) or MapSet.member?(@always_at_home, key)

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
  @before_fields ~w(name ingredient_id quantity unit category added_at expires_at expires_source provenance belief last_seen_at)a

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

  @typedoc "What `use_up/2` changed, so `put_back/2` can undo it."
  @type used :: %{id: integer(), name: String.t(), belief: String.t(), last_seen_at: DateTime.t()}

  @doc """
  A dinner was cooked with `names`: what the pantry held of them is believed missing now, except
  what outlasts a dinner (dry goods, spices, condiments). Buying it again brings it back, as any
  stronger belief does. Returns what changed, for `put_back/2`.
  """
  @spec use_up(Scope.t(), [String.t()]) :: [used()]
  def use_up(%Scope{} = scope, names) do
    keys = MapSet.new(names, &Ingredient.to_key/1)

    items =
      scope
      |> list_usable()
      |> Repo.preload(:ingredient)
      |> Enum.filter(&(Ingredient.to_key(&1.name) in keys and not lasts?(&1)))

    ids = Enum.map(items, & &1.id)

    Repo.update_all(
      from(p in PantryItem, where: p.id in ^ids),
      [set: [belief: "missing", last_seen_at: now()]],
      Scope.repo_opts(scope)
    )

    Enum.map(items, &Map.take(&1, [:id, :name, :belief, :last_seen_at]))
  end

  defp lasts?(%PantryItem{ingredient: %Ingredient{category: category}}), do: category in @lasts
  defp lasts?(_item), do: false

  @doc "Undoes `use_up/2`: each row's belief as it was."
  @spec put_back(Scope.t(), [used()]) :: :ok
  def put_back(%Scope{} = scope, used) do
    for %{id: id, belief: belief, last_seen_at: seen} <- used do
      Repo.update_all(
        from(p in PantryItem, where: p.id == ^id),
        [set: [belief: belief, last_seen_at: seen]],
        Scope.repo_opts(scope)
      )
    end

    :ok
  end

  @doc """
  Something put away by hand on Hemma, as written ("2 l mjölk" read by `Tore.Shop.parse_line/1`):
  sure now, added to its ingredient's row if there is one (a row used up comes back). A name
  Tore hasn't learned yet is learned in the background, so it finds its group.
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
      if matched_key == nil, do: Tore.Pantry.Learn.later(scope, [name])
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

  @doc "Gone: believed missing, as after a dinner (`use_up/2`), until it's bought again."
  @spec mark_gone(Scope.t(), integer()) :: {:ok, PantryItem.t()} | {:error, :not_found}
  def mark_gone(%Scope{} = scope, item_id) do
    with {:ok, item} <- fetch_item(scope, item_id) do
      item |> Ecto.Changeset.change(belief: "missing", last_seen_at: now()) |> Repo.update()
    end
  end

  defp fetch_item(scope, item_id) do
    case Repo.get(PantryItem, item_id, Scope.repo_opts(scope)) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  @doc """
  Keeps the photo of a scanned pack for its ingredient, unless it has one (the household's own
  wins). The photo is a nicety: one that won't come is logged and the scan goes on without it.
  """
  @spec keep_picture(Scope.t(), Ingredient.t(), String.t()) :: :ok
  def keep_picture(%Scope{} = scope, %Ingredient{image_path: nil} = ingredient, url) do
    http = Application.fetch_env!(:tore, :http_client)

    with {:ok, body} when is_binary(body) <- http.fetch(url),
         :ok <- store_picture(scope, ingredient, body) do
      :ok
    else
      failed ->
        Logger.warning("Couldn't keep the photo for #{ingredient.name}: #{inspect(failed)}")
        :ok
    end
  end

  def keep_picture(%Scope{}, %Ingredient{}, _url), do: :ok

  @doc """
  The household's own photo of an ingredient (a JPEG the phone has already made small), in place
  of whatever it had.
  """
  @spec put_picture(Scope.t(), integer(), binary()) :: :ok | {:error, term()}
  def put_picture(%Scope{} = scope, ingredient_id, jpeg) when is_binary(jpeg) do
    case Repo.get(Ingredient, ingredient_id, Scope.repo_opts(scope)) do
      nil -> {:error, :not_found}
      ingredient -> store_picture(scope, ingredient, jpeg)
    end
  end

  defp store_picture(scope, ingredient, jpeg) do
    storage = Tore.Storage.client()
    bucket = Tore.Storage.Buckets.recipes()
    key = "households/#{scope.household_id}/products/#{ingredient.id}/#{Ecto.UUID.generate()}.jpg"

    with {:ok, _url} <- storage.put_object(bucket, key, jpeg, content_type: "image/jpeg") do
      ingredient |> Ecto.Changeset.change(image_path: key) |> Repo.update!()
      if ingredient.image_path, do: storage.delete_object(bucket, ingredient.image_path)
      :ok
    end
  end

  @doc "The photo kept for an ingredient, if there is one."
  @spec picture(Scope.t(), integer()) :: {:ok, binary()} | :none
  def picture(%Scope{} = scope, ingredient_id) do
    with %Ingredient{image_path: key} when is_binary(key) <-
           Repo.get(Ingredient, ingredient_id, Scope.repo_opts(scope)),
         {:ok, body} <- Tore.Storage.client().get_object(Tore.Storage.Buckets.recipes(), key) do
      {:ok, body}
    else
      _ -> :none
    end
  end

  @doc "Everything kept, with its ingredient, which says where it belongs once learned."
  @spec list_kept(Scope.t()) :: [PantryItem.t()]
  def list_kept(%Scope{} = scope), do: scope |> list_inventory() |> Repo.preload(:ingredient)

  @doc """
  Everything kept, each with its half-life when it's eaten between meals: the household's own
  rhythm when Basics has learned one, otherwise Jev's guess (`Tore.Pantry.Lasts`).
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
      select: {p, b.interval_days, i.lasts}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.map(fn {item, rhythm, lasts} ->
      %{item | half_life_days: rhythm || Tore.Pantry.Lasts.half_life_days(lasts)}
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
