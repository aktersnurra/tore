defmodule Tore.Mcp.SessionToken do
  @moduledoc """
  The token Tore gives a harness job for `/mcp`: signed with the endpoint's secret, naming one
  household and the job, and valid until the job's time limit runs out. It signs in as that
  household with no person, so a job can only ever touch the household it was started for,
  whatever it is told. Nothing to register with Pocket ID and no long-lived secret on the guest.
  """

  alias Tore.Scope

  @salt "harness session"
  # The longest any job may hold a token, whatever it asks for.
  @max_seconds 2 * 60 * 60

  @doc "A token for `job` in this household, good for `seconds`."
  @spec mint(pos_integer(), String.t(), integer()) :: String.t()
  def mint(household_id, job, seconds) when is_integer(household_id) and is_binary(job) do
    expires = System.system_time(:second) + min(seconds, @max_seconds)

    Phoenix.Token.sign(ToreWeb.Endpoint, @salt, %{household: household_id, job: job, exp: expires})
  end

  @spec verify(String.t()) :: {:ok, Scope.t()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    with {:ok, %{household: household_id, exp: expires}} <-
           Phoenix.Token.verify(ToreWeb.Endpoint, @salt, token, max_age: @max_seconds),
         true <- System.system_time(:second) < expires || {:error, :expired} do
      {:ok, Scope.for_household(household_id)}
    end
  end
end
