defmodule Tore.Harness.Kind do
  @moduledoc """
  What a kind of run does at each step. `Tore.Harness.Runs` drives the steps; a kind only says
  what each one means for it.

  | Step             | May do                              | May not do         |
  |------------------|-------------------------------------|--------------------|
  | `propose`        | LLM (through `Tore.LLM`), reads     | write domain state |
  | `resolve`        | LLM, reads                          | write domain state |
  | `verify`         | nothing: a pure check               | any effect         |
  | `apply_proposal` | database writes, in the run's transaction | LLM, HTTP, storage |
  | `after_commit`   | best-effort effects, such as deleting a photo | |

  A proposal is a registered artifact or a list of them (`Tore.Harness.Artifact.Registry`),
  because a proposal that waits for review is stored on the run until it is confirmed.

  `ctx` always holds `:scope`, and from `resolve` on also `:run`, the row as it stands. The
  caller's own keys, such as a photo's bytes, are there on the run that started it and not on a
  later `confirm`, so anything `apply_proposal` needs must be in the run's `input` or the proposal.
  """

  alias Tore.Harness.{KitchenRun, Undo}

  @type proposal :: struct() | [struct()]
  @type ctx :: %{required(:scope) => Tore.Scope.t(), optional(atom()) => term()}
  @type usage :: %{
          prompt_tokens: integer(),
          completion_tokens: integer(),
          cost_usd: number() | Decimal.t()
        }

  @callback kind() :: String.t()
  @callback surface() :: :today | :plan | :shop | nil
  @callback open(ctx()) :: %{input: map(), actor: :user | :system | :mcp}

  @callback propose(KitchenRun.t(), ctx()) ::
              {:ok, proposal(), usage()} | {:ask, question :: String.t()} | {:error, term()}
  @callback resolve(proposal(), ctx()) :: {:ok, proposal()} | {:error, term()}
  @callback verify(proposal(), ctx()) :: :ok | {:fail, code :: atom(), repair :: term()}

  @doc "Why someone must look at this first, or nil to apply it straight away."
  @callback review_question(proposal()) :: String.t() | nil

  @doc """
  Database writes only. Runs inside the run's transaction. A check that no longer holds once
  inside it (the state changed since `verify`) returns `{:fail, code, repair}`, which rolls back
  and fails the run as a verifier would.
  """
  @callback apply_proposal(proposal(), ctx()) ::
              {:ok, Undo.t(), artifacts :: [struct()]}
              | {:fail, code :: atom(), repair :: term()}
              | {:error, term()}

  @doc "Called after each committed status change; the kind matches on `run.status`."
  @callback after_commit(KitchenRun.t()) :: :ok

  @optional_callbacks propose: 2, resolve: 2, after_commit: 1
end
