defmodule Tore.AiOperations do
  alias Tore.{Repo, Scope, AiOperations.AiOperation}
  import Ecto.Query

  @spec log(Scope.t(), map()) :: {:ok, AiOperation.t()} | {:error, Ecto.Changeset.t()}
  def log(%Scope{} = scope, attrs) do
    %AiOperation{household_id: scope.household_id}
    |> AiOperation.changeset(attrs)
    |> Repo.insert()
  end

  @spec list_for_run(Scope.t(), String.t()) :: [AiOperation.t()]
  def list_for_run(%Scope{} = scope, run_stream_id) do
    from(o in AiOperation,
      where: o.run_stream_id == ^run_stream_id,
      order_by: [asc: o.step_index]
    )
    |> Repo.all(Scope.repo_opts(scope))
  end
end
