defmodule Tore.Shop do
  alias Tore.{Basics, EventStore, Scope, Shop.Decider, Shop.Commands, Shop.Aggregator, Pantry}
  alias Tore.Pantry.{Learn, Match}
  alias Tore.Recipes.Ingredient
  alias Phoenix.PubSub

  @pubsub Tore.PubSub
  @valid_sections Ingredient.sections()

  @doc "The topic a household's shopping-list changes are broadcast on."
  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{household_id: id}), do: "shop_list:household:#{id}"

  def load_list(%Scope{} = scope, list_id) do
    EventStore.load(scope, list_id, Decider)
  end

  @units ~w(g hg kg ml cl dl l msk tsk krm st förp paket pkt burk)
  @line ~r/^(\d+(?:[.,]\d+)?)\s*(?:(#{Enum.join(@units, "|")})\.?\s+|\s+)(\S.*)$/iu

  @doc """
  A line typed into the list, read as people write it: "2 l mjölk" is two litres of milk, "6 ägg"
  six eggs, "bananer" just bananas. Returns `{name, quantity, unit}`; the unit is lower-cased.
  """
  @spec parse_line(String.t()) :: {String.t(), Decimal.t() | nil, String.t() | nil}
  def parse_line(line) do
    line = String.trim(line)

    with [_, amount, unit, name] <- Regex.run(@line, line),
         # "2 l" alone names no item; keep the line as typed rather than add an "l".
         false <- unit == "" and String.downcase(name) in @units do
      quantity = amount |> String.replace(",", ".") |> Decimal.new()
      {String.trim(name), quantity, if(unit == "", do: nil, else: String.downcase(unit))}
    else
      _ -> {line, nil, nil}
    end
  end

  @doc """
  For each ingredient key (`Ingredient.to_key/1`), the first dinner on the week's plan from
  `today` on that needs it: `%{date:, title:}`. Derived from the plan, so a list made by hand
  gets the same line as one built from it.
  """
  @spec dinners_for(Scope.t(), Date.t(), Date.t()) :: %{
          String.t() => %{date: Date.t(), title: String.t()}
        }
  def dinners_for(%Scope{} = scope, %Date{} = week_start, %Date{} = today) do
    {:ok, plan} = Tore.Planning.load_plan(scope, Tore.Streams.plan(scope, week_start))

    days =
      for i <- 0..6,
          date = Date.add(week_start, i),
          Date.compare(date, today) != :lt,
          slot = plan.slots[Tore.Streams.slot_key(date)],
          slot && slot.recipe_id && !slot.skipped && !slot[:leftover],
          do: {date, slot.recipe_id}

    recipes =
      scope |> Tore.Recipes.get_many(Enum.map(days, &elem(&1, 1))) |> Map.new(&{&1.id, &1})

    days
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn {date, id}, acc ->
      case recipes[id] do
        nil ->
          acc

        recipe ->
          recipe.recipe_ingredients
          |> Map.new(&{Ingredient.to_key(&1.ingredient.name), %{date: date, title: recipe.title}})
          |> then(&Map.merge(acc, &1))
      end
    end)
  end

  @doc """
  The week's list: `recipe_ids`' ingredients, then the basics due that week (`Tore.Basics`), each
  in its section, without what the pantry holds: an ingredient with a usable pantry row is left
  out. Exact, with no model, so a near miss stays on the list rather than dropping off it.
  """
  @spec items_for(Scope.t(), [integer()], Date.t()) :: [map()]
  def items_for(%Scope{} = scope, recipe_ids, %Date{} = week_start) do
    at_home = scope |> Pantry.list_usable() |> MapSet.new(&Ingredient.to_key(&1.name))
    dinners = Aggregator.aggregate_by_ids(scope, recipe_ids)
    on_list = MapSet.new(dinners, &Ingredient.to_key(&1.name))

    :ok = Basics.learn(scope, Tore.Clock.today())

    basics =
      for item <- Basics.items(scope, week_start),
          not MapSet.member?(on_list, Ingredient.to_key(item.name)),
          do: Map.merge(item, %{id: Ecto.UUID.generate(), checked: false})

    (dinners ++ basics)
    |> Enum.reject(&MapSet.member?(at_home, Ingredient.to_key(&1.name)))
    |> Enum.map(&Map.put(&1, :section, section_for(scope, &1.name)))
  end

  @doc """
  The shop section `name` goes in: its ingredient's, or `:other` for a name not learned yet, with
  no model. `resettle_sections/2` moves it once the name is learned.
  """
  @spec section_for(Scope.t(), String.t()) :: atom()
  def section_for(%Scope{} = scope, name) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, %{category: category}} when category in @valid_sections ->
        String.to_existing_atom(category)

      _ ->
        :other
    end
  end

  @doc "Moves unticked items still in `:other` to the section their name has learned since."
  @spec resettle_sections(Scope.t(), String.t()) :: :ok
  def resettle_sections(%Scope{} = scope, list_id) do
    {:ok, state} = load_list(scope, list_id)

    for %{section: :other, checked: false} = item <- Map.values(state.items),
        section = section_for(scope, item.name),
        section != :other do
      run(scope, list_id, %Commands.SetItemSection{item_id: item.id, section: section})
    end

    :ok
  end

  @doc "Learns the names on `list_id` in the background, then moves them to their sections."
  @spec learn(Scope.t(), String.t(), [String.t()]) :: :ok
  def learn(%Scope{} = scope, list_id, names),
    do: Learn.later(scope, names, fn -> resettle_sections(scope, list_id) end)

  @doc """
  Puts `name` on the list. A name already on it and not yet ticked off stays as it is, so
  "Put on the list" pressed twice, or from two screens, gives one line: `{:ok, []}`.
  """
  def add_item(%Scope{} = scope, list_id, name, quantity, unit, user_id) do
    {:ok, state} = load_list(scope, list_id)

    if Enum.any?(Map.values(state.items), &(!&1.checked and same_name?(&1.name, name))) do
      {:ok, []}
    else
      result =
        run(scope, list_id, %Commands.AddItem{
          item_id: Ecto.UUID.generate(),
          name: name,
          quantity: quantity,
          unit: unit,
          section: section_for(scope, name),
          added_by: user_id
        })

      learn(scope, list_id, [name])
      result
    end
  end

  defp same_name?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  @doc """
  Annotate shop list items with the pantry's belief about whether they're
  already at home. docs/specs/ui.md §16.5: items the user probably already has
  render with a `?` prefix and inline copy. `:missing` rows don't count
  as "have it" and are ignored.

  Adds two fields per item: `:pantry_belief` (`:confirmed | :probable |
  :uncertain | nil`) and `:pantry_last_seen_at` (`DateTime.t() | nil`).
  """
  def annotate_with_pantry_belief(%Scope{} = scope, items) do
    now = DateTime.utc_now()
    today = Tore.Clock.today()

    pantry =
      Pantry.list_inventory(scope)
      |> Enum.map(fn row ->
        {row, Tore.Pantry.PantryItem.effective_belief(row, now, today), name_tokens(row.name)}
      end)
      |> Enum.reject(fn {_row, eff, _tokens} -> eff == :missing end)

    Enum.map(items, fn item ->
      case match_pantry_row(item.name, pantry) do
        {row, eff} ->
          item
          |> Map.put(:pantry_belief, eff)
          |> Map.put(:pantry_last_seen_at, row.last_seen_at)

        nil ->
          item
          |> Map.put(:pantry_belief, nil)
          |> Map.put(:pantry_last_seen_at, nil)
      end
    end)
  end

  defp match_pantry_row(name, pantry) when is_binary(name) do
    needle_tokens = name_tokens(name)

    case Enum.find(pantry, fn {_row, _eff, row_tokens} ->
           tokens_overlap?(needle_tokens, row_tokens)
         end) do
      {row, eff, _} -> {row, eff}
      nil -> nil
    end
  end

  defp match_pantry_row(_, _), do: nil

  # Tokenise on non-word characters; drop tokens shorter than 3 chars so
  # filler words ("of", "1l") and short ambiguous fragments ("ham" inside
  # "graham") can't trigger a false match. Whole-token equality only —
  # substring overlap is too greedy when the user reads the result as
  # "we're sure you have this at home".
  defp name_tokens(nil), do: MapSet.new()

  defp name_tokens(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  defp tokens_overlap?(a, b), do: not MapSet.disjoint?(a, b)

  @doc "Removes an item. A basic taken off the list is wanted less often (`Tore.Basics.removed/2`)."
  def remove_item(%Scope{} = scope, list_id, item_id, user_id) do
    {:ok, state} = load_list(scope, list_id)
    result = run(scope, list_id, %Commands.RemoveItem{item_id: item_id, removed_by: user_id})

    with {:ok, _} <- result,
         %{basic: true, name: name} <- state.items[item_id],
         do: Basics.removed(scope, name)

    result
  end

  def check_item(%Scope{} = scope, list_id, item_id, user_id) do
    with {:ok, state} <- EventStore.load(scope, list_id, Decider),
         {:ok, events} <-
           Decider.decide(%Commands.CheckItem{item_id: item_id, checked_by: user_id}, state),
         :ok <- EventStore.append(scope, list_id, events) do
      PubSub.broadcast(@pubsub, topic(scope), {:events, events})
      item = Map.get(state.items, item_id)

      if item do
        pantry_checkoff(scope, [%{name: item.name, quantity: item.quantity, unit: item.unit}])
        Basics.bought(scope, [item.name], Tore.Clock.today())
      end

      {:ok, events}
    end
  end

  @doc """
  Puts checked-off items (`name`, `quantity`, `unit`) into the pantry, as a pantry run, with no
  model. A name Tore hasn't seen is learned afterwards (`Tore.Pantry.Learn`).
  """
  def pantry_checkoff(%Scope{} = scope, items) do
    result =
      Tore.Harness.Runs.start(scope, Tore.Harness.Kinds.PantryUpdate, %{
        channel: :grocery_checkoff,
        items: items
      })

    Tore.Pantry.Learn.later(scope, Enum.map(items, & &1.name))
    result
  end

  @doc """
  Resolve a free-text item name to a single uncheckéd item on `list_id`
  by case-insensitive bidirectional substring match.
  """
  @spec find_item_fuzzy(Scope.t(), String.t(), String.t()) ::
          {:ok, {String.t(), map()}}
          | {:ambiguous, [{String.t(), map()}]}
          | {:error, :not_found}
  def find_item_fuzzy(%Scope{} = scope, list_id, query) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    case load_list(scope, list_id) do
      {:ok, %{items: items}} when map_size(items) > 0 ->
        matches =
          items
          |> Enum.reject(fn {_id, it} -> it.checked end)
          |> Enum.filter(fn {_id, it} ->
            name = String.downcase(it.name)
            String.contains?(name, needle) or String.contains?(needle, name)
          end)

        case matches do
          [] -> {:error, :not_found}
          [one] -> {:ok, one}
          many -> {:ambiguous, many}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def uncheck_item(%Scope{} = scope, list_id, item_id, user_id) do
    run(scope, list_id, %Commands.UncheckItem{item_id: item_id, unchecked_by: user_id})
  end

  def export_list(%Scope{} = scope, list_id) do
    with {:ok, state} <- EventStore.load(scope, list_id, Decider) do
      lines =
        state.items
        |> Map.values()
        |> Enum.reject(& &1.checked)
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn item ->
          qty = if item.quantity, do: "#{item.quantity} #{item.unit} ", else: ""
          "- #{qty}#{item.name}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  defp run(scope, list_id, command) do
    with {:ok, events} <- append(scope, list_id, command) do
      PubSub.broadcast(@pubsub, topic(scope), {:events, events})
      {:ok, events}
    end
  end

  @doc """
  Decides `command` against the list and appends its events, without telling anyone: a run calls
  this inside its transaction, then `announce/1` once it has committed. A `BuildList` replaces
  the list.
  """
  @spec append(Scope.t(), String.t(), Commands.t()) ::
          {:ok, [Tore.Shop.Events.t()]} | {:error, term()}
  def append(%Scope{} = scope, list_id, %Commands.BuildList{} = command) do
    EventStore.reset(scope, list_id)
    append_decided(scope, list_id, command)
  end

  def append(%Scope{} = scope, list_id, command), do: append_decided(scope, list_id, command)

  defp append_decided(scope, list_id, command) do
    with {:ok, state} <- EventStore.load(scope, list_id, Decider),
         {:ok, events} <- Decider.decide(command, state),
         :ok <- EventStore.append(scope, list_id, events) do
      {:ok, events}
    end
  end

  @doc "Tells shopping screens the list changed."
  @spec announce(Scope.t()) :: :ok
  def announce(%Scope{} = scope), do: PubSub.broadcast(@pubsub, topic(scope), {:events, []})
end
