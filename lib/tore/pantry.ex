defmodule Tore.Pantry do
  import Ecto.Query
  alias Tore.{Repo, Scope}
  alias Tore.Pantry.{Expiry, PantryItem}
  alias Tore.Recipes.Ingredient

  def parse_image(%Scope{} = scope, image_binary) do
    {system, user} = Tore.LLM.Prompts.parse_pantry_image(Tore.Household.locale(scope))

    with {:ok, data, _usage} <-
           Tore.LLM.vision(scope, [{:image, image_binary}], system, user,
             response_format: Tore.LLM.Prompts.pantry_json_schema(),
             feature: :parse_shelf_photo
           ) do
      items =
        Enum.map(data["items"] || [], fn it ->
          %{
            name: it["name"],
            quantity: parse_decimal(it["quantity"]),
            unit: it["unit"],
            category: it["category"],
            expires_on: Expiry.parse_date(it["expires_on"])
          }
        end)

      {:ok, items}
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp parse_decimal(s) when is_binary(s), do: Decimal.new(s)

  @doc """
  Catalogue snapshot used to ground the LLM canonicaliser.
  """
  @spec catalogue(Scope.t()) :: [%{key: String.t(), name: String.t(), category: String.t() | nil}]
  def catalogue(%Scope{} = scope) do
    Repo.all(
      from(i in Ingredient, select: %{key: i.key, name: i.name, category: i.category}),
      Scope.repo_opts(scope)
    )
  end

  @doc """
  Send raw pantry items through the LLM canonicaliser. Returns a list of
  `{raw_name, catalogue_name, category, default_unit, matched_key}` maps.
  """
  @spec canonicalise(Scope.t(), [map()], String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def canonicalise(%Scope{} = scope, items, locale) do
    {system, user} =
      Tore.LLM.Prompts.canonicalise_pantry_items(items, locale, catalogue(scope))

    case Tore.LLM.text(scope, system, user,
           response_format: Tore.LLM.Prompts.canonicalise_pantry_schema(),
           feature: :canonicalise_pantry
         ) do
      {:ok, %{"items" => norm}, _usage} when is_list(norm) ->
        {:ok,
         Enum.map(norm, fn it ->
           %{
             raw_name: it["raw_name"],
             catalogue_name: it["catalogue_name"],
             category: it["category"],
             default_unit: it["default_unit"],
             matched_key: it["matched_key"],
             shelf_life_days: Expiry.parse_shelf_life(it["shelf_life_days"])
           }
         end)}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

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
      {:ok, {item, change, before}} -> {:ok, item, change, before}
      {:error, _} = err -> err
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
    case {to_decimal(existing_qty), to_decimal(incoming_qty)} do
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

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

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

  @doc "What's in the pantry and still within its date, if it has one."
  @spec list_usable(Scope.t()) :: [PantryItem.t()]
  def list_usable(%Scope{} = scope) do
    today = Tore.Clock.today()
    Enum.reject(list_inventory(scope), &PantryItem.past_date?(&1, today))
  end

  @spec list_inventory(Scope.t()) :: [PantryItem.t()]
  def list_inventory(%Scope{} = scope) do
    Repo.all(from(p in PantryItem, order_by: p.name), Scope.repo_opts(scope))
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
