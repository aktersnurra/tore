defmodule Tore.Household.Memory do
  @moduledoc """
  What Tore remembers about a household, kept the way the Hermes agent keeps memory: two bounded
  parts of short entries, shared by everyone in the household.

    * `profile`: who you cook for: names, ages, schedules, tastes, how you shop and cook.
    * `notes`: what has been learned: what gets skipped or swapped, what worked, agreements.

  AI writes go through runs (`Kinds.MemoryReview`), so each entry names the run that wrote it and
  can be undone. A person removes an entry directly, from Settings. Forgotten entries stay stored
  with the time they were forgotten. Prompts read both parts once per turn, through `snapshot/1`.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Household.Memory.Ops

  @type t :: %__MODULE__{}

  schema "household_memory" do
    field :household_id, :integer
    field :store, :string
    field :text, :string
    field :supersedes_id, :integer
    field :run_id, :string
    field :forgotten_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @labels %{
    "profile" => "HOUSEHOLD PROFILE (who you cook for)",
    "notes" => "NOTES (what you have learned about how they eat)"
  }

  @doc "The household's live entries, or one part's, oldest first."
  @spec list(Scope.t()) :: [t()]
  def list(%Scope{} = scope) do
    from(m in __MODULE__,
      where: is_nil(m.forgotten_at),
      order_by: [asc: m.inserted_at, asc: m.id]
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  @spec list(Scope.t(), String.t()) :: [t()]
  def list(%Scope{} = scope, store), do: scope |> list() |> Enum.filter(&(&1.store == store))

  @doc "Each part's entries and how full it is."
  @spec stores(Scope.t()) :: [
          %{store: String.t(), entries: [t()], usage: String.t(), percent: non_neg_integer()}
        ]
  def stores(%Scope{} = scope) do
    entries = list(scope)

    for store <- Ops.stores() do
      kept = Enum.filter(entries, &(&1.store == store))
      texts = Enum.map(kept, & &1.text)

      %{
        store: store,
        entries: kept,
        usage: Ops.usage(store, texts),
        percent: Ops.percent(store, texts)
      }
    end
  end

  @doc """
  Both parts as a prompt reads them: a header with the usage, then the entries separated by `§`.
  Nil when both are empty.
  """
  @spec snapshot(Scope.t()) :: String.t() | nil
  def snapshot(%Scope{} = scope) do
    stores = stores(scope)

    if Enum.all?(stores, &(&1.entries == [])) do
      nil
    else
      rule = String.duplicate("═", 46)

      Enum.map_join(stores, "\n\n", fn %{store: store, entries: entries} = part ->
        body =
          case entries do
            [] -> "(empty)"
            entries -> Enum.map_join(entries, Ops.separator(), & &1.text)
          end

        "#{rule}\n#{@labels[store]} [#{part.percent}% — #{part.usage} chars]\n#{rule}\n#{body}"
      end)
    end
  end

  @doc """
  Writes a plan from `Ops.plan/3` for one part, as the run `run_id`. Call it inside the run's
  transaction. Returns the ids it added and forgot, for the undo, and what changed, for the
  receipt.
  """
  @spec write(Scope.t(), String.t(), Ops.plan(), String.t()) ::
          %{added: [integer()], forgotten: [integer()], changes: [map()]}
  def write(%Scope{} = scope, store, plan, run_id) do
    now = DateTime.utc_now()
    forgotten = Enum.filter(list(scope, store), &(&1.id in plan.forget))

    Enum.each(forgotten, &(&1 |> Ecto.Changeset.change(forgotten_at: now) |> Repo.update!()))

    added =
      Enum.map(plan.add, fn %{text: text, supersedes: supersedes} ->
        Repo.insert!(%__MODULE__{
          household_id: scope.household_id,
          store: store,
          text: text,
          supersedes_id: supersedes,
          run_id: run_id
        })
      end)

    superseded = MapSet.new(added, & &1.supersedes_id)

    changes =
      Enum.map(
        added,
        &%{"kind" => if(&1.supersedes_id, do: "updated", else: "noted"), "text" => &1.text}
      ) ++
        for(
          m <- forgotten,
          not MapSet.member?(superseded, m.id),
          do: %{"kind" => "forgot", "text" => m.text}
        )

    %{added: Enum.map(added, & &1.id), forgotten: Enum.map(forgotten, & &1.id), changes: changes}
  end

  @doc "Forgets one entry. Removing in Settings does this, with no run."
  @spec forget(Scope.t(), integer()) :: :ok | {:error, :not_found}
  def forget(%Scope{} = scope, id) do
    case Repo.update_all(
           from(m in __MODULE__, where: m.id == ^id and is_nil(m.forgotten_at)),
           [set: [forgotten_at: DateTime.utc_now()]],
           Scope.repo_opts(scope)
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Undoes a run's write: forgets what it added and brings back what it forgot. As elsewhere in run
  core, a later edit doesn't block an earlier undo, so an added entry already forgotten stays
  forgotten. An entry written by a run that has itself been reverted stays forgotten too, so
  undoing chained runs in any order ends where they started. Raises when an entry isn't the
  household's, so a revert never claims what it didn't do.
  """
  @spec restore(Scope.t(), [integer()], [integer()]) :: :ok
  def restore(%Scope{} = scope, added_ids, forgotten_ids) do
    opts = Scope.repo_opts(scope)
    ids = Enum.uniq(added_ids ++ forgotten_ids)
    expected = length(ids)
    ^expected = Repo.aggregate(from(m in __MODULE__, where: m.id in ^ids), :count, opts)

    Repo.update_all(
      from(m in __MODULE__, where: m.id in ^added_ids and is_nil(m.forgotten_at)),
      [set: [forgotten_at: DateTime.utc_now()]],
      opts
    )

    reverted = from(r in Tore.Harness.KitchenRun, where: r.status == :reverted, select: r.id)

    Repo.update_all(
      from(m in __MODULE__, where: m.id in ^forgotten_ids and m.run_id not in subquery(reverted)),
      [set: [forgotten_at: nil]],
      opts
    )

    :ok
  end
end
