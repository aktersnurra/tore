defmodule Tore.Shop do
  alias Tore.{EventStore, Scope, Shop.Decider, Shop.Commands, Shop.Aggregator, Pantry}
  alias Phoenix.PubSub

  @pubsub Tore.PubSub
  @topic "shop_list"

  def load_list(%Scope{} = scope, list_id) do
    EventStore.load(scope, list_id, Decider)
  end

  def build_list(%Scope{} = scope, list_id, week_start, recipe_ids) do
    all_items = Aggregator.aggregate_by_ids(scope, recipe_ids)
    pantry = Pantry.list_usable(scope)

    items =
      if pantry == [] do
        all_items
      else
        case filter_pantry_items(all_items, pantry) do
          {:ok, filtered} -> filtered
          _ -> all_items
        end
      end

    EventStore.reset(scope, list_id)
    run(scope, list_id, %Commands.BuildList{week_start: week_start, items: items})
  end

  def add_item(%Scope{} = scope, list_id, name, quantity, unit, user_id) do
    section =
      case classify_grocery_item(name) do
        {:ok, s} -> s
        _ -> :other
      end

    run(scope, list_id, %Commands.AddItem{
      item_id: Ecto.UUID.generate(),
      name: name,
      quantity: quantity,
      unit: unit,
      section: section,
      added_by: user_id
    })
  end

  @valid_sections ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)

  defp filter_pantry_items(ingredients, pantry) do
    {system, user} = Tore.LLM.Prompts.filter_pantry_items(ingredients, pantry)

    fallback = Application.get_env(:tore, :openrouter_check_model_fallback, "openai/gpt-oss-120b")

    case Tore.LLM.text(system, user,
           model: fallback,
           response_format: Tore.LLM.Prompts.filter_pantry_schema()
         ) do
      {:ok, items, _usage} when is_list(items) -> {:ok, build_filter_result(items)}
      {:ok, %{"items" => items}, _usage} when is_list(items) -> {:ok, build_filter_result(items)}
      {:ok, _, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp classify_grocery_item(name) do
    {system, user} = Tore.LLM.Prompts.classify_grocery_item(name)

    case Tore.LLM.text(system, user, []) do
      {:ok, %{"section" => section}, _usage} -> {:ok, to_section_atom(section)}
      {:ok, _, _} -> {:error, :invalid_response}
      {:error, _} = err -> err
    end
  end

  defp build_filter_result(items) do
    items
    |> Enum.map(&Map.put(&1, "name", &1["name"] || &1["item"] || &1["ingredient"]))
    |> Enum.filter(&is_binary(&1["name"]))
    |> Enum.map(fn i ->
      qty =
        case i["quantity"] do
          nil -> nil
          n when is_number(n) -> n
          s when is_binary(s) -> s
          _ -> nil
        end

      %{
        id: Ecto.UUID.generate(),
        name: i["name"],
        quantity: qty,
        unit: i["unit"],
        section: to_section_atom(i["section"]),
        checked: false
      }
    end)
  end

  defp to_section_atom(s) when is_binary(s) and s in @valid_sections, do: String.to_atom(s)
  defp to_section_atom(_), do: :other

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

    pantry =
      Pantry.list_inventory(scope)
      |> Enum.map(fn row ->
        {row, Tore.Pantry.PantryItem.effective_belief(row, now), name_tokens(row.name)}
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

  def remove_item(%Scope{} = scope, list_id, item_id, user_id) do
    run(scope, list_id, %Commands.RemoveItem{item_id: item_id, removed_by: user_id})
  end

  def check_item(%Scope{} = scope, list_id, item_id, user_id) do
    with {:ok, state} <- EventStore.load(scope, list_id, Decider),
         {:ok, events} <-
           Decider.decide(%Commands.CheckItem{item_id: item_id, checked_by: user_id}, state),
         :ok <- EventStore.append(scope, list_id, events) do
      PubSub.broadcast(@pubsub, @topic, {:events, events})
      item = Map.get(state.items, item_id)

      if item do
        Tore.Harness.Orchestrator.dispatch(:pantry_belief_update_run, %{
          household_id: scope.household_id,
          user_id: user_id,
          channel: :grocery_checkoff,
          items: [%{name: item.name, quantity: item.quantity, unit: item.unit}]
        })
      end

      {:ok, events}
    end
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
    with {:ok, state} <- EventStore.load(scope, list_id, Decider),
         {:ok, events} <- Decider.decide(command, state),
         :ok <- EventStore.append(scope, list_id, events) do
      PubSub.broadcast(@pubsub, @topic, {:events, events})
      {:ok, events}
    end
  end
end
