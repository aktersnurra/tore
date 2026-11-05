defmodule Tore.Pantry do
  import Ecto.Query
  alias Tore.Repo
  alias Tore.Pantry.{Expiry, PantryItem}
  alias Tore.Recipes.Ingredient

  def parse_image(image_binary) do
    {system, user} = Tore.LLM.Prompts.parse_pantry_image(Tore.Household.locale())

    with {:ok, data, _usage} <-
           Tore.LLM.vision([{:image, image_binary}], system, user,
             response_format: Tore.LLM.Prompts.pantry_json_schema()
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
  @spec catalogue() :: [%{key: String.t(), name: String.t(), category: String.t() | nil}]
  def catalogue do
    Repo.all(from i in Ingredient, select: %{key: i.key, name: i.name, category: i.category})
  end

  @doc """
  Send raw pantry items through the LLM canonicaliser. Returns a list of
  `{raw_name, catalogue_name, category, default_unit, matched_key}` maps.
  """
  @spec canonicalise([map()], String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def canonicalise(items, locale) do
    {system, user} = Tore.LLM.Prompts.canonicalise_pantry_items(items, locale, catalogue())

    case Tore.LLM.text(system, user,
           response_format: Tore.LLM.Prompts.canonicalise_pantry_schema()
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

  Returns `{:ok, %PantryItem{}, :added | :bumped}`.
  """
  @spec upsert_belief(map()) ::
          {:ok, PantryItem.t(), :added | :bumped, map() | nil} | {:error, term()}
  def upsert_belief(attrs) do
    Repo.transaction(fn ->
      ingredient = find_or_create_ingredient(attrs)

      case Repo.get_by(PantryItem, ingredient_id: ingredient.id) do
        nil ->
          {:ok, item} =
            attrs
            |> base_pantry_attrs(ingredient)
            |> Map.put(:quantity, attrs[:quantity])
            |> Map.merge(expiry_attrs(%{expires_at: nil, expires_source: nil}, attrs, ingredient))
            |> add_item()

          {item, :added, nil}

        existing ->
          before = snapshot_attrs(existing)
          {:ok, item} = bump_existing(existing, attrs, ingredient)
          {item, :bumped, before}
      end
    end)
    |> case do
      {:ok, {item, change, before}} -> {:ok, item, change, before}
      {:error, _} = err -> err
    end
  end

  defp snapshot_attrs(%PantryItem{} = item) do
    %{
      quantity: item.quantity && Decimal.to_string(item.quantity),
      unit: item.unit,
      last_seen_at: item.last_seen_at,
      provenance: item.provenance,
      belief: item.belief,
      added_at: item.added_at,
      expires_at: item.expires_at,
      expires_source: item.expires_source
    }
  end

  defp expiry_attrs(current, attrs, ingredient) do
    {expires_at, expires_source} =
      Expiry.next(current, attrs, ingredient.shelf_life_days, Date.utc_today())

    %{expires_at: expires_at, expires_source: expires_source}
  end

  defp find_or_create_ingredient(attrs) do
    key =
      case attrs[:matched_key] do
        k when is_binary(k) and k != "" -> k
        _ -> Ingredient.to_key(attrs[:catalogue_name] || attrs[:name] || "")
      end

    case Repo.get_by(Ingredient, key: key) do
      nil ->
        {:ok, ing} =
          %Ingredient{}
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
  defp fill_shelf_life(%Ingredient{shelf_life_days: nil} = ingredient, days) when is_integer(days),
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
        added_at: if(Expiry.bought?(attrs), do: Date.utc_today(), else: item.added_at),
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
      {nil, q} -> {q, existing_unit || incoming_unit}
      {q, nil} -> {q, existing_unit || incoming_unit}
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

  @spec add_item(map()) :: {:ok, PantryItem.t()} | {:error, Ecto.Changeset.t()}
  def add_item(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:added_at, Date.utc_today())
      |> Map.put_new(:provenance, "manual")
      |> Map.put_new(:last_seen_at, now)

    attrs = Map.put_new(attrs, :belief, PantryItem.derive_belief(attrs[:provenance]))

    %PantryItem{} |> PantryItem.changeset(attrs) |> Repo.insert()
  end

  @spec remove_item(integer()) :: :ok | {:error, :not_found}
  def remove_item(item_id) do
    case Repo.get(PantryItem, item_id) do
      nil -> {:error, :not_found}
      item -> Repo.delete(item) |> then(fn _ -> :ok end)
    end
  end

  @doc """
  Set or clear an item's expiry date by hand. The date stays until the item is
  bought again, and the days since it came in become the ingredient's shelf
  life, so the next guess is better.
  """
  @spec set_expiry(integer(), Date.t() | nil) ::
          {:ok, PantryItem.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_expiry(item_id, expires_at) do
    case Repo.get(PantryItem, item_id) do
      nil ->
        {:error, :not_found}

      item ->
        Repo.transaction(fn ->
          learn_shelf_life(item, expires_at)

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

  defp learn_shelf_life(%PantryItem{ingredient_id: id} = item, %Date{} = expires_at)
       when not is_nil(id) do
    case Expiry.parse_shelf_life(Date.diff(expires_at, item.added_at)) do
      nil ->
        :ok

      days ->
        Ingredient
        |> Repo.get!(id)
        |> Ecto.Changeset.change(shelf_life_days: days)
        |> Repo.update!()
    end
  end

  defp learn_shelf_life(_item, _expires_at), do: :ok

  @doc "What's in the pantry and still within its date, if it has one."
  @spec list_usable() :: [PantryItem.t()]
  def list_usable do
    today = Date.utc_today()
    Enum.reject(list_inventory(), &PantryItem.past_date?(&1, today))
  end

  @spec list_inventory() :: [PantryItem.t()]
  def list_inventory do
    Repo.all(from p in PantryItem, order_by: p.name)
  end

  @doc """
  Resolve a free-text name to a single pantry item by case-insensitive
  bidirectional substring match. Returns the item if exactly one row
  matches, otherwise `{:ambiguous, candidates}` or `{:error, :not_found}`.

  Used by the agent's tool path so "we're out of milk" can find the
  pantry row without the agent needing to know item ids.
  """
  @spec find_by_name_fuzzy(String.t()) ::
          {:ok, PantryItem.t()} | {:ambiguous, [PantryItem.t()]} | {:error, :not_found}
  def find_by_name_fuzzy(query) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    if needle == "" do
      {:error, :not_found}
    else
      matches =
        list_inventory()
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
  # UI_SPEC §16.5 — pantry rows render as belief, not category.
  @belief_order ~w[confirmed probable uncertain missing]a

  @spec list_inventory_by_belief() :: [{atom(), [PantryItem.t()]}]
  def list_inventory_by_belief do
    now = DateTime.utc_now()
    items = Repo.all(from p in PantryItem, order_by: p.name)
    grouped = Enum.group_by(items, &PantryItem.effective_belief(&1, now))

    @belief_order
    |> Enum.flat_map(fn key ->
      case Map.get(grouped, key) do
        nil -> []
        bucket -> [{key, bucket}]
      end
    end)
  end
end
