defmodule Tore.Household.Memory.Ops do
  @moduledoc """
  Pure: a batch of memory operations, as the Hermes agent's memory tool takes them, checked
  against one store's entries. `plan/3` takes the store, its entries (oldest first) and the
  operations, and returns what to add and what to forget, or why nothing changes.

    * `add` (`content`) appends an entry; an exact duplicate is not added, and says so;
    * `patch` (`old_text`, `content`) finds the one entry that is `old_text` or contains it
      once, and replaces that span with `content`; a whole-entry match wins over substrings;
    * `remove` (`old_text`) forgets the one entry that is or contains it.

  The batch is all or nothing: an operation that matches no entry or several, or content that
  is empty, names an internal id, states an allergy or intolerance, or reads as an injection
  (instructions to the model, credentials, invisible characters), rejects it. Allergies are
  refused because `Preferences` holds them, where `PlanVerifier` enforces them; a note would
  look like a safety rule that nothing enforces. The store's limit is checked on the
  batch's result, so freeing space and adding go in one batch. A rejection carries the
  current entries and usage, the closest entries when nothing matched, and `"refused" =>
  "allergy"` for an allergy, so Capture can point to where allergies go.
  """

  @stores ~w[profile notes]
  @limits %{"profile" => 1_375, "notes" => 2_200}
  @separator "\n§\n"
  @max_operations 10

  # Slot keys and other snake_case names the household never says.
  @internal_id ~r/\b[a-z]+_[a-z0-9_]+\b/

  # A blunt word check, in Swedish and English: a false refusal only costs a note.
  @allergy ~r/(allerg|intoleran|celiak|celiac|coeliac|anafylax|anaphyla)/iu

  @type store :: String.t()
  @type entry :: %{id: pos_integer(), text: String.t()}
  @type plan :: %{
          add: [%{text: String.t(), supersedes: pos_integer() | nil}],
          forget: [pos_integer()],
          notes: [String.t()]
        }

  @spec stores() :: [store()]
  def stores, do: @stores

  @spec limit(store()) :: pos_integer()
  def limit(store), do: Map.fetch!(@limits, store)

  @spec separator() :: String.t()
  def separator, do: @separator

  @doc "Characters the entries take as the store holds them, separators included."
  @spec size([String.t()]) :: non_neg_integer()
  def size(texts), do: texts |> Enum.join(@separator) |> String.length()

  @doc "`1,474/2,200`."
  @spec usage(store(), [String.t()]) :: String.t()
  def usage(store, texts), do: "#{thousands(size(texts))}/#{thousands(limit(store))}"

  @spec percent(store(), [String.t()]) :: non_neg_integer()
  def percent(store, texts), do: round(size(texts) * 100 / limit(store))

  @spec plan(store(), [entry()], term()) :: {:ok, plan()} | {:error, map()}
  def plan(store, entries, operations) when store in @stores and is_list(entries) do
    working = Enum.map(entries, &%{id: &1.id, text: &1.text, supersedes: nil})

    with :ok <- check_operations(operations),
         {:ok, working, notes} <- run(operations, working, []),
         :ok <- check_limit(store, entries, working) do
      kept = MapSet.new(for %{id: id} <- working, is_integer(id), do: id)

      {:ok,
       %{
         add:
           for(
             %{id: id} = e <- working,
             not is_integer(id),
             do: %{text: e.text, supersedes: e.supersedes}
           ),
         forget: for(%{id: id} <- entries, not MapSet.member?(kept, id), do: id),
         notes: Enum.reverse(notes)
       }}
    else
      {:error, message} -> {:error, rejection(store, entries, message)}
      {:error, message, extra} -> {:error, Map.merge(rejection(store, entries, message), extra)}
    end
  end

  def plan(_store, entries, _operations),
    do: {:error, rejection(nil, entries, "target must be \"profile\" or \"notes\"")}

  defp check_operations([_ | _] = operations) when length(operations) <= @max_operations,
    do:
      if(Enum.all?(operations, &is_map/1), do: :ok, else: {:error, "each operation is an object"})

  defp check_operations(_operations),
    do: {:error, "operations must be a list of 1 to #{@max_operations} operations"}

  defp run([], working, notes), do: {:ok, working, notes}

  defp run([operation | rest], working, notes) do
    case step(operation, working) do
      {:ok, working} -> run(rest, working, notes)
      {:ok, working, note} -> run(rest, working, [note | notes])
      error -> error
    end
  end

  defp step(%{"action" => "add", "content" => content} = op, working) when map_size(op) == 2 do
    with {:ok, text} <- content(content) do
      if Enum.any?(working, &(&1.text == text)),
        do: {:ok, working, "already noted, no duplicate added: #{text}"},
        else: {:ok, working ++ [%{id: new_id(working), text: text, supersedes: nil}]}
    end
  end

  defp step(%{"action" => "patch", "old_text" => old, "content" => content} = op, working)
       when map_size(op) == 3 and is_binary(old) and is_binary(content) do
    old = String.trim(old)

    with {:ok, entry} <- find(old, working),
         :ok <- once(entry.text, old),
         {:ok, text} <- content(String.replace(entry.text, old, content, global: false)) do
      cond do
        # A patch that changes nothing is not a change.
        text == entry.text ->
          {:ok, working, "unchanged: #{text}"}

        is_integer(entry.id) ->
          patched = %{id: {:patched, entry.id}, text: text, supersedes: entry.id}
          {:ok, Enum.map(working, &if(&1.id == entry.id, do: patched, else: &1))}

        true ->
          {:ok, Enum.map(working, &if(&1.id == entry.id, do: %{&1 | text: text}, else: &1))}
      end
    end
  end

  defp step(%{"action" => "remove", "old_text" => old} = op, working)
       when map_size(op) == 2 and is_binary(old) do
    with {:ok, entry} <- find(String.trim(old), working) do
      {:ok, Enum.reject(working, &(&1.id == entry.id))}
    end
  end

  defp step(%{"action" => "replace"}, _working),
    do: {:error, "replace is not an action; use patch with old_text and content"}

  defp step(%{"action" => action}, _working) when action in ~w[add patch remove],
    do: {:error, "#{action} takes " <> fields(action)}

  defp step(_operation, _working), do: {:error, "action must be add, patch or remove"}

  # A new entry's id is unique among the entries now in the batch, so a later operation
  # names it alone, whatever was removed before it.
  defp new_id(working) do
    taken = for %{id: {:new, n}} <- working, do: n
    {:new, Enum.max(taken, fn -> -1 end) + 1}
  end

  defp fields("add"), do: "content"
  defp fields("patch"), do: "old_text and content"
  defp fields("remove"), do: "old_text"

  # The entry `old` names: the one that is it, else the one that contains it.
  defp find("", _working), do: {:error, "old_text is empty"}

  defp find(old, working) do
    case Enum.filter(working, &(&1.text == old)) do
      [entry] -> {:ok, entry}
      _ -> find_within(old, working)
    end
  end

  defp find_within(old, working) do
    case Enum.filter(working, &String.contains?(&1.text, old)) do
      [entry] ->
        {:ok, entry}

      [] ->
        {:error, "no entry matches old_text", %{"closest_entries" => closest(old, working)}}

      many ->
        {:error, "old_text matches #{length(many)} entries; give more of the one you mean",
         %{"matching_entries" => Enum.map(many, & &1.text)}}
    end
  end

  defp once(text, old) do
    case String.split(text, old) do
      [_, _] -> :ok
      _ -> {:error, "old_text occurs more than once in the entry; give more of it"}
    end
  end

  defp closest(old, working) do
    working
    |> Enum.sort_by(&String.jaro_distance(String.downcase(&1.text), String.downcase(old)), :desc)
    |> Enum.take(3)
    |> Enum.map(& &1.text)
  end

  defp content(content) when is_binary(content) do
    text = content |> String.trim() |> String.replace(~r/[ \t]+/, " ")

    cond do
      text == "" ->
        {:error, "content is empty; to delete an entry use remove"}

      unsafe?(text) ->
        {:error,
         "content was blocked: it reads as instructions, a credential or hidden characters"}

      Regex.match?(@internal_id, text) ->
        {:error,
         "content names an internal id; write it as the household would (Monday dinner, not mon_dinner)"}

      Regex.match?(@allergy, text) ->
        {:error,
         "content states an allergy or intolerance; those belong in the household's preferences, " <>
           "where planning enforces them, so ask them to add it there", %{"refused" => "allergy"}}

      true ->
        {:ok, text}
    end
  end

  defp content(_content), do: {:error, "content must be text"}

  # What has no place in a memory read back into a prompt: instructions to the model,
  # secrets, and characters no one can see.
  @unsafe [
    ~r/\b(ignore|disregard|override)\b.{0,40}\b(instructions?|system prompt|your prompt)\b/iu,
    ~r/\b(system prompt|you are now|new instructions)\b/iu,
    ~r/\bact as (an?|the|my|your) (ai|assistant|model|system|chatbot)\b/iu,
    ~r/<\/?\s*(system|assistant|tool)\b/iu,
    ~r/\b(api[ _-]?key|password|passwd|secret|bearer|token)\b\s*[:=]\s*[A-Za-z0-9_\-.\/+]{8,}/iu,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----|\bssh-(rsa|ed25519)\b|authorized_keys/u,
    ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}]/u
  ]

  defp unsafe?(text), do: Enum.any?(@unsafe, &Regex.match?(&1, text))

  # The limit is checked on the batch's result. A store already over it (notes kept before
  # the limit existed) still takes any batch that does not make it larger, so it can always
  # be brought down.
  defp check_limit(store, entries, working) do
    used = working |> Enum.map(& &1.text) |> size()
    allowed = max(limit(store), entries |> Enum.map(& &1.text) |> size())

    if used <= allowed,
      do: :ok,
      else:
        {:error,
         "#{store} would hold #{thousands(used)}/#{thousands(limit(store))} chars. " <>
           "Retry with one batch that frees #{thousands(used - allowed)} chars " <>
           "(patch entries shorter, merge or remove some) and adds the new entry."}
  end

  defp rejection(store, entries, message) do
    texts = Enum.map(entries, & &1.text)

    %{
      "success" => false,
      "error" => message,
      "current_entries" => texts,
      "usage" => if(store in @stores, do: usage(store, texts), else: nil)
    }
  end

  defp thousands(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()
end
