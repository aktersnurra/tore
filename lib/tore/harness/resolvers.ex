defmodule Tore.Harness.Resolvers do
  @moduledoc """
  Resolver tools (SPEC.md §A.6.2): natural-language reference → typed handle.
  V1 implements recipes via `resolve_recipe/1`; NL slot references (day
  words, "tonight/today/tomorrow", assigned-recipe titles) are resolved
  structurally by `resolve_slot/2` — the slot domain is closed, so results
  are slot keys, not handles. Pure read — no writes, no LLM calls.
  """

  alias Tore.Harness.Handles
  alias Tore.Recipes

  @accept 0.7
  @floor 0.45
  @clear_gap 0.1

  @days ~w(mon tue wed thu fri sat sun)
  @day_words %{
    "monday" => "mon",
    "tuesday" => "tue",
    "wednesday" => "wed",
    "thursday" => "thu",
    "friday" => "fri",
    "saturday" => "sat",
    "sunday" => "sun",
    "mon" => "mon",
    "tue" => "tue",
    "wed" => "wed",
    "thu" => "thu",
    "fri" => "fri",
    "sat" => "sat",
    "sun" => "sun"
  }
  @day_labels %{
    "mon" => "Monday",
    "tue" => "Tuesday",
    "wed" => "Wednesday",
    "thu" => "Thursday",
    "fri" => "Friday",
    "sat" => "Saturday",
    "sun" => "Sunday"
  }

  def resolve_recipe(%Tore.Scope{} = scope, query) when is_binary(query) do
    q = normalize(query)

    scored =
      Recipes.list(scope)
      |> Enum.map(fn r -> {similarity(q, normalize(r.title)), r} end)
      |> Enum.sort_by(fn {s, _} -> s end, :desc)

    case scored do
      [] ->
        :not_found

      [{best, _} | _] when best < @floor ->
        :not_found

      [{best, r}] when best >= @accept ->
        {:ok, to_handle(r, best)}

      [{best, r}, {second, _} | _] when best >= @accept and best - second >= @clear_gap ->
        {:ok, to_handle(r, best)}

      plausible ->
        {:ambiguous,
         plausible
         |> Enum.take_while(fn {s, _} -> s >= @floor end)
         |> Enum.take(3)
         |> Enum.map(fn {s, r} -> to_handle(r, s) end)}
    end
  end

  defp to_handle(recipe, score),
    do: Handles.recipe(recipe.id, recipe.title, :resolve_recipe, Float.round(score, 2))

  defp similarity(a, b) do
    jaro = String.jaro_distance(a, b)
    if String.contains?(b, a), do: max(jaro, 0.65), else: jaro
  end

  defp normalize(s), do: s |> String.downcase() |> String.trim()

  @doc """
  Resolve an English natural-language slot reference to a structural slot key.
  Slots are a closed domain — no ref indirection needed (SPEC §A.6.2).
  opts: slots: %{slot_key => recipe_title | nil}, today: Date.t()
  """
  def resolve_slot(reference, opts) when is_binary(reference) do
    slots = Keyword.fetch!(opts, :slots)
    today = Keyword.fetch!(opts, :today)
    q = normalize(reference)

    cond do
      day = relative_day(q, today) -> ok_slot("#{day}_dinner")
      day = word_day(q) -> ok_slot("#{day}_dinner")
      true -> by_recipe(q, slots)
    end
  end

  defp relative_day(q, today) do
    cond do
      String.contains?(q, "tonight") or String.contains?(q, "today") -> day_of(today)
      String.contains?(q, "tomorrow") -> day_of(Date.add(today, 1))
      true -> nil
    end
  end

  defp day_of(date), do: Enum.at(@days, Date.day_of_week(date) - 1)

  defp word_day(q) do
    words = String.split(q)

    Enum.find_value(@day_words, fn {word, day} ->
      if word in words, do: day
    end)
  end

  defp by_recipe(q, slots) do
    scored =
      slots
      |> Enum.reject(fn {_k, title} -> is_nil(title) end)
      |> Enum.map(fn {k, title} -> {similarity_containing(q, normalize(title)), k} end)
      |> Enum.sort_by(fn {s, _} -> s end, :desc)

    case scored do
      [] ->
        :not_found

      [{best, _} | _] when best < @floor ->
        :not_found

      [{best, k}] when best >= @accept ->
        ok_slot(k)

      [{best, k}, {second, _} | _] when best >= @accept and best - second >= @clear_gap ->
        ok_slot(k)

      plausible ->
        {:ambiguous,
         plausible
         |> Enum.take_while(fn {s, _} -> s >= @floor end)
         |> Enum.take(3)
         |> Enum.map(fn {_s, k} -> slot_result(k) end)}
    end
  end

  # "the chicken skewers slot" contains the title, not vice versa — check both
  # ways. Titles with no word overlap and no containment get their raw Jaro
  # score discounted, so unrelated titles can't out-rank a genuine partial
  # match ("salmon" in "the salmon dinner") purely on character coincidence.
  # Titles sharing a word ("Salmon pasta" / "Salmon soup" both match "salmon")
  # land close enough together to be ambiguous rather than one winning.
  defp similarity_containing(q, title) do
    jaro = String.jaro_distance(q, title)

    cond do
      String.contains?(q, title) or String.contains?(title, q) -> max(jaro, 0.8)
      shared_word?(q, title) -> max(jaro, 0.5)
      true -> jaro * 0.5
    end
  end

  defp shared_word?(q, title) do
    q_words = q |> String.split() |> MapSet.new()
    title_words = title |> String.split() |> MapSet.new()
    not MapSet.disjoint?(q_words, title_words)
  end

  defp ok_slot(slot_key), do: {:ok, slot_result(slot_key)}

  defp slot_result(slot_key) do
    [day, meal] = String.split(slot_key, "_", parts: 2)
    %{slot_key: slot_key, label: "#{@day_labels[day]} #{meal}"}
  end
end
