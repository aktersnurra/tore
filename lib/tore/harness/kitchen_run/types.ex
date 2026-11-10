defmodule Tore.Harness.KitchenRun.Types do
  @moduledoc """
  Column types for `runs`. Each casts by encoding then decoding, so a value in memory is
  always one the database returns unchanged, and each loads strictly: bad data raises.
  """

  defmodule JsonMap do
    @moduledoc """
    A JSON object with string keys. Atom keys and atom values become strings on cast. A value
    JSON can't hold, or an atom key and a string key with the same name, is refused.
    """
    use Ecto.Type

    def type, do: :string

    def cast(map) when is_map(map) and not is_struct(map) do
      with {:ok, json} <- Jason.encode(map),
           {:ok, decoded} when map_size(decoded) == map_size(map) <- Jason.decode(json) do
        {:ok, decoded}
      else
        _ -> :error
      end
    rescue
      Protocol.UndefinedError -> :error
    end

    def cast(_), do: :error

    def dump(map) when is_map(map), do: Jason.encode(map)
    def dump(_), do: :error

    def load(json) when is_binary(json) do
      case Jason.decode!(json) do
        map when is_map(map) -> {:ok, map}
      end
    end
  end

  defmodule Artifacts do
    @moduledoc "A list of registered artifact structs, stored with each one's `__kind__`."
    use Ecto.Type

    alias Tore.Harness.Artifact

    def type, do: :string

    def cast(artifacts) when is_list(artifacts) do
      {:ok, artifacts |> Enum.map(&Artifact.to_json/1) |> round_trip() |> Enum.map(&from_json!/1)}
    rescue
      _ in [ArgumentError, KeyError, FunctionClauseError, UndefinedFunctionError] -> :error
    end

    def cast(_), do: :error

    def dump(artifacts) when is_list(artifacts),
      do: Jason.encode(Enum.map(artifacts, &Artifact.to_json/1))

    def dump(_), do: :error

    def load(json) when is_binary(json) do
      case Jason.decode!(json) do
        list when is_list(list) -> {:ok, Enum.map(list, &from_json!/1)}
      end
    end

    defp round_trip(term), do: term |> Jason.encode!() |> Jason.decode!()

    defp from_json!(%{"__kind__" => kind} = json) do
      case Artifact.Registry.lookup(kind) do
        {:ok, module} -> module.from_json(json)
        :error -> raise ArgumentError, "unknown artifact kind #{inspect(kind)}"
      end
    end
  end

  defmodule RepairAction do
    @moduledoc "What a failed run suggests: `:reject`, `{:edit_plan, slot_keys}` or nothing."
    use Ecto.Type

    def type, do: :string

    def cast(:reject), do: {:ok, :reject}

    def cast({:edit_plan, slots} = action) when is_list(slots) do
      if Enum.all?(slots, &is_binary/1), do: {:ok, action}, else: :error
    end

    def cast(_), do: :error

    def dump(:reject), do: {:ok, "reject"}
    def dump({:edit_plan, slots}), do: Jason.encode(%{"edit_plan" => slots})
    def dump(_), do: :error

    def load("reject"), do: {:ok, :reject}

    def load(json) when is_binary(json) do
      case Jason.decode!(json) do
        %{"edit_plan" => slots} when is_list(slots) -> {:ok, {:edit_plan, slots}}
      end
    end
  end

  defmodule Undo do
    @moduledoc "A `Tore.Harness.Undo.t()`."
    use Ecto.Type

    alias Tore.Harness.Undo, as: U

    def type, do: :string

    def cast(undo) do
      {:ok, undo |> U.encode() |> Jason.encode!() |> Jason.decode!() |> U.decode()}
    rescue
      _ in [ArgumentError, KeyError, FunctionClauseError, Protocol.UndefinedError] -> :error
    end

    def dump(undo) do
      {:ok, undo |> U.encode() |> Jason.encode!()}
    rescue
      _ in [ArgumentError, KeyError, FunctionClauseError] -> :error
    end

    def load(json) when is_binary(json), do: {:ok, json |> Jason.decode!() |> U.decode()}
  end

  defmodule Usd do
    @moduledoc """
    A Decimal kept in plain notation. SQLite stores decimals as plain text, so `1E+2` would
    otherwise come back as `100` and differ from the run that was written.
    """
    use Ecto.Type

    def type, do: :string

    def cast(value) do
      case Ecto.Type.cast(:decimal, value) do
        {:ok, d} -> {:ok, d |> Decimal.to_string(:normal) |> Decimal.new()}
        :error -> :error
      end
    end

    def dump(%Decimal{} = d), do: {:ok, Decimal.to_string(d, :normal)}
    def dump(_), do: :error

    def load(s) when is_binary(s), do: {:ok, Decimal.new(s)}
  end
end
