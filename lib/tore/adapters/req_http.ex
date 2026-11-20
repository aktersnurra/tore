defmodule Tore.Adapters.ReqHTTP do
  @behaviour Tore.HTTP

  @impl Tore.HTTP
  def fetch(url), do: fetch(url, [])

  @impl Tore.HTTP
  def fetch(url, headers) do
    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:req_error, reason}}
    end
  end
end
