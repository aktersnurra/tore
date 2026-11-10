defmodule Tore.Capture.Uploads do
  @moduledoc """
  Dedup checks for uploaded image bytes, keyed on SHA-256 of the raw
  binary, scoped per household. The same household uploading the same
  bytes twice is treated as a no-op pointing at the original `stream_id`.
  """

  import Ecto.Query

  alias Tore.Capture.UploadedImage
  alias Tore.{Repo, Scope}

  @doc "Hex SHA-256 of the binary."
  @spec content_hash(binary()) :: String.t()
  def content_hash(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  @doc """
  Returns `{:ok, stream_id}` if the bytes are already on record for this
  household, otherwise `:fresh`.
  """
  @spec already_uploaded?(Scope.t(), String.t()) :: {:ok, String.t()} | :fresh
  def already_uploaded?(%Scope{} = scope, content_hash) do
    case Repo.one(
           from(u in UploadedImage,
             where: u.content_hash == ^content_hash,
             select: u.stream_id,
             limit: 1
           ),
           Scope.repo_opts(scope)
         ) do
      nil -> :fresh
      stream_id -> {:ok, stream_id}
    end
  end

  @doc """
  Record an upload. Returns `{:ok, stream_id}` if recorded or `{:duplicate,
  existing_stream_id}` if the household already uploaded these bytes. The
  unique index does the heavy lifting — this is the race-safe path.
  """
  @spec record(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:duplicate, String.t()}
  def record(%Scope{} = scope, content_hash, stream_id, kind) do
    attrs = %{
      household_id: scope.household_id,
      content_hash: content_hash,
      stream_id: stream_id,
      kind: kind
    }

    case Repo.insert(UploadedImage.changeset(attrs)) do
      {:ok, _row} ->
        {:ok, stream_id}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :household_id) or duplicate_error?(errors) do
          {:ok, existing} = already_uploaded?(scope, content_hash)
          {:duplicate, existing}
        else
          {:ok, stream_id}
        end
    end
  end

  defp duplicate_error?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
