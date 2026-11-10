defmodule Tore.Storage.RunPhotos do
  @moduledoc """
  Storage helpers for photos attached to a `KitchenRun` (uploaded receipts,
  shelf photos, fridge photos). Photos are stored in the `runs` bucket
  under `households/<household_id>/<stream_id>/<uuid>.jpg` and deleted when
  the run terminates.

  See `Tore.Storage.Buckets` for the bucket convention.
  """

  alias Tore.Scope
  alias Tore.Storage.Buckets

  @doc "The key prefix every photo of the household's runs lives under."
  @spec prefix(Scope.t()) :: String.t()
  def prefix(%Scope{household_id: id}), do: "households/#{id}/"

  @doc """
  Persist `binary` for `stream_id` and return the S3 key. The key is what
  the orchestrator stores on the run's `Opened.input.image_path` — pass it
  back to `url/1` to render, or to `delete/1` to clean up.
  """
  @spec store(Scope.t(), String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def store(%Scope{} = scope, stream_id, binary)
      when is_binary(stream_id) and is_binary(binary) do
    key = "#{prefix(scope)}#{stream_id}/#{Ecto.UUID.generate()}.jpg"

    case storage().put_object(Buckets.runs(), key, binary, content_type: "image/jpeg") do
      {:ok, _url} -> {:ok, key}
      {:error, _} = err -> err
    end
  end

  @doc "Public URL for a previously-stored run photo key."
  @spec url(String.t()) :: String.t()
  def url(key) when is_binary(key) do
    storage().get_object_url(Buckets.runs(), key)
  end

  @doc """
  Fire-and-forget delete. Spawned under `Tore.TaskSupervisor` so an S3 hiccup
  doesn't block the caller; the weekly orphan-sweep is the safety net.
  """
  @spec delete_async(String.t() | nil) :: :ok
  def delete_async(nil), do: :ok

  def delete_async(key) when is_binary(key) do
    Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> delete(key) end)
    :ok
  end

  @doc "Synchronous delete. Used by the weekly orphan reaper."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    case storage().delete_object(Buckets.runs(), key) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp storage, do: Tore.Storage.client()
end
