defmodule Tore.Harness.Kinds.Planner do
  @moduledoc """
  What the plan kinds share: running `PlannerAgent`, and verifying and applying its proposal.

  A proposal is a `PlanDiff`, applied straight away once `PlanVerifier` passes, or a
  `RecipeProposal`, which always waits for review: generated or imported recipes never save
  themselves. Confirming one saves the recipe and assigns it to the slot the planner meant it for.

  Applying records each touched slot as it was, so undo puts back what was there rather than
  clearing it. Plan screens hear about the change after the run commits.
  """

  alias Tore.{AiOperations, Household, Planning, Recipes, Scope}
  alias Tore.Harness.{Capsules, Handles, PlanDiffBuilder}
  alias Tore.Harness.Artifact.{PlanDiff, RecipeProposal}

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    MemoryCapsule,
    PantryBeliefsCapsule,
    WeekPlanCapsule
  }

  alias Tore.Harness.Verifier.{PlanVerifier, RecipeProposalVerifier}
  alias Tore.LLM.PlannerAgent
  alias Tore.Planning.{Decider, Events}

  @capsules [HouseholdPreferencesCapsule, MemoryCapsule, WeekPlanCapsule, PantryBeliefsCapsule]

  @doc "The run's input: where the plan lives, plus `extra`."
  @spec input(map(), map()) :: map()
  def input(ctx, extra \\ %{}) do
    Map.merge(
      %{"plan_stream_id" => ctx.plan_stream_id, "week_start" => Date.to_iso8601(ctx.week_start)},
      extra
    )
  end

  @doc """
  Runs the agent loop on `user_text`. Each tool step is logged to `ai_operations` under the run.
  `ctx` holds `:plan_stream_id`, `:week_start` and optionally `:scoped_slot` and `:extra_tools`
  (the seam tests drive the loop with).
  """
  @spec propose(Tore.Harness.KitchenRun.t(), map(), String.t(), keyword()) ::
          {:ok, PlanDiff.t() | RecipeProposal.t(), map()} | {:ask, String.t()} | {:error, term()}
  def propose(run, %{scope: scope} = ctx, user_text, opts \\ []) do
    with {:ok, plan} <- Planning.load_plan(scope, ctx.plan_stream_id),
         {:ok, loop} <-
           PlannerAgent.run(system_prompt(scope, ctx), user_text, agent_ctx(run, ctx, plan), opts) do
      Enum.each(loop.tool_trace, &log_step(scope, run.id, &1))

      case loop.result do
        {:question, question} ->
          {:ask, question}

        {:proposal, %RecipeProposal{} = proposal, pending} ->
          {:ok, %{proposal | pending_assignment: pending(pending)}, usage(loop)}

        {kind, _} when kind in [:message, :capped] ->
          diff = %{PlanDiffBuilder.build(loop.tool_trace, ctx) | plan_events: loop.plan_events}
          {:ok, diff, usage(loop)}
      end
    end
  end

  @spec verify(PlanDiff.t() | RecipeProposal.t(), map()) :: :ok | {:fail, atom(), term()}
  def verify(%PlanDiff{} = diff, %{scope: scope}) do
    {:ok, plan} = Planning.load_plan(scope, diff.plan_stream_id)

    PlanVerifier.verify(diff, %{
      plan_state: Enum.reduce(diff.plan_events, plan, &Decider.evolve(&2, &1)),
      preferences: Household.get_preferences(scope),
      scope: scope
    })
  end

  def verify(%RecipeProposal{} = proposal, %{scope: scope}),
    do:
      RecipeProposalVerifier.verify(proposal, %{
        existing_recipes: Recipes.catalog_fingerprints(scope)
      })

  @spec review_question(PlanDiff.t() | RecipeProposal.t()) :: String.t() | nil
  def review_question(%PlanDiff{}), do: nil
  def review_question(%RecipeProposal{}), do: "Review this recipe before saving it."

  @spec apply_proposal(PlanDiff.t() | RecipeProposal.t(), map()) ::
          {:ok, Tore.Harness.Undo.t(), [struct()]} | {:fail, atom(), term()} | {:error, term()}
  def apply_proposal(%PlanDiff{} = diff, %{scope: scope}) do
    with {:ok, undo} <- change_plan(scope, diff.plan_stream_id, diff.plan_events) do
      {:ok, {:steps, undo}, [diff]}
    end
  end

  def apply_proposal(%RecipeProposal{} = proposal, %{scope: scope, run: run}) do
    # On confirm the scope is the person confirming; a weekly run opened as the system has no user.
    user_id = scope.user_id || run.user_id

    with {:ok, recipe} <- Recipes.create(scope, recipe_attrs(proposal, user_id), image: false),
         {:ok, slot_undo} <- assign_pending(scope, run, proposal, recipe) do
      {:ok, {:steps, [{:delete_recipe, recipe.id} | slot_undo]}, [proposal]}
    end
  end

  @spec after_commit(Tore.Harness.KitchenRun.t()) :: :ok
  def after_commit(%{status: :applied} = run) do
    scope = Scope.for_household(run.household_id)

    # A confirmed recipe gets its picture now that the recipe is committed: the page's own if
    # it came from one, otherwise a generated one.
    image_url = Enum.find_value(run.artifacts, &(match?(%RecipeProposal{}, &1) && &1.image_url))

    with {:steps, steps} <- run.undo,
         do: for({:delete_recipe, id} <- steps, do: Recipes.start_image(scope, id, image_url))

    Planning.announce(scope)
  end

  def after_commit(%{status: :reverted} = run),
    do: Planning.announce(Scope.for_household(run.household_id))

  def after_commit(_run), do: :ok

  @doc "Appends `events` and returns the undo steps that put the touched slots back."
  @spec change_plan(Scope.t(), String.t(), [Tore.Planning.Events.t()]) ::
          {:ok, [Tore.Harness.Undo.step()]} | {:error, term()}
  def change_plan(_scope, _plan_id, []), do: {:ok, []}

  def change_plan(scope, plan_id, events) do
    {:ok, plan} = Planning.load_plan(scope, plan_id)
    before = Planning.slots_before(plan, events |> Enum.map(& &1.slot_key) |> Enum.uniq())

    with :ok <- Planning.append_events(scope, plan_id, events) do
      {:ok, [{:restore_plan_slots, plan_id, before}]}
    end
  end

  defp assign_pending(_scope, _run, %RecipeProposal{pending_assignment: nil}, _recipe),
    do: {:ok, []}

  # The proposal may have waited hours for review: a day someone has pinned or marked as
  # eating out since then stays as it is.
  defp assign_pending(scope, run, %RecipeProposal{pending_assignment: pending}, recipe) do
    plan_id = run.input["plan_stream_id"]
    slot_key = pending[:slot_key] || pending["slot_key"]
    {:ok, plan} = Planning.load_plan(scope, plan_id)

    cond do
      Map.has_key?(plan.pins, slot_key) ->
        {:fail, :slot_pinned, {:edit_plan, [slot_key]}}

      Tore.Planning.State.eating_out?(plan.slots[slot_key]) ->
        {:fail, :slot_eating_out, {:edit_plan, [slot_key]}}

      true ->
        event = %Events.RecipeAssigned{
          slot_key: slot_key,
          recipe_id: recipe.id,
          servings: pending[:servings] || pending["servings"] || recipe.base_servings || 4
        }

        change_plan(scope, plan_id, [event])
    end
  end

  # An empty map means the planner asked for a recipe with no slot in mind.
  defp pending(pending) when pending == %{}, do: nil
  defp pending(pending), do: pending

  defp recipe_attrs(%RecipeProposal{} = proposal, user_id) do
    %{
      title: proposal.title,
      description: proposal.description,
      instructions: proposal.instructions,
      base_servings: proposal.base_servings,
      prep_time_minutes: proposal.prep_time_minutes,
      cook_time_minutes: proposal.cook_time_minutes,
      source_url: proposal.source_url,
      steps: proposal.steps,
      created_by: user_id,
      tags: proposal.tags,
      ingredients: Enum.map(proposal.ingredients, &ingredient_attrs/1)
    }
  end

  defp ingredient_attrs(ing),
    do: %{name: ing[:name], quantity: decimal(ing[:quantity]), unit: ing[:unit]}

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _rest} -> d
      :error -> nil
    end
  end

  defp usage(loop) do
    Enum.reduce(
      loop.usage_per_step,
      %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)},
      fn step, acc ->
        %{
          prompt_tokens: acc.prompt_tokens + (step.prompt_tokens || 0),
          completion_tokens: acc.completion_tokens + (step.completion_tokens || 0),
          cost_usd: Decimal.add(acc.cost_usd, Decimal.new(to_string(step.cost_usd || 0)))
        }
      end
    )
  end

  defp log_step(scope, run_id, entry) do
    {:ok, _} =
      AiOperations.log(scope, %{
        run_stream_id: run_id,
        kind: "planner_agent." <> Atom.to_string(entry.step_kind),
        step_index: entry.step_index,
        payload: Jason.encode!(entry.payload),
        result: ""
      })
  end

  defp agent_ctx(run, ctx, plan) do
    %{
      plan_id: ctx.plan_stream_id,
      week_start: ctx.week_start,
      household_id: ctx.scope.household_id,
      run_stream_id: run.id,
      working_plan: plan,
      handles: scoped_handles(ctx[:scoped_slot]),
      extra_tools: Map.get(ctx, :extra_tools, [])
    }
  end

  defp scoped_handles(nil), do: %{}

  defp scoped_handles(slot_key),
    do: Handles.register(%{}, Handles.slot(slot_key, String.replace(slot_key, "_", " ")))

  defp system_prompt(scope, ctx) do
    capsule_ctx = %{
      household_id: scope.household_id,
      plan_stream_id: ctx.plan_stream_id,
      week_start: ctx.week_start
    }

    [
      preamble(),
      "Today is #{Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")}.",
      week_mode_line(scope),
      Capsules.compose(@capsules, capsule_ctx)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp week_mode_line(scope) do
    case Tore.WeekMode.mode_prompt_fragment(Tore.WeekMode.get_current_mode(scope)) do
      nil -> nil
      fragment -> "Current week mode: #{fragment}"
    end
  end

  defp preamble do
    """
    You are the planner agent for Tore, a household meal planner.

    You operate by calling tools, not by replying in prose. When the user makes
    a request that maps to a planning action (assign, swap, skip, mark as
    leftovers, set servings, remove), call the corresponding tool. When you
    need to look up recipes, pantry, or deals to decide what to do, call the
    matching read tool first. Recipes are referenced by the `ref` returned
    from search_recipes or resolve_recipe — never invent or guess a ref, and
    never reuse a ref from an earlier turn. When the user refers to a slot in
    natural language ("tonight", a weekday, "the salmon dinner") instead of
    naming a slot key, call resolve_slot to get the structural slot_key
    before calling a slot-targeting action. When resolve_recipe or
    resolve_slot returns multiple ambiguous matches, or the user's request is
    otherwise ambiguous, call ask_user with a specific clarifying question
    instead of guessing.

    After your tool calls succeed, give a one-sentence confirmation of what you
    did. Do not narrate or restate the plan. If you cannot perform the action
    (a tool returned an error), explain what went wrong in one sentence.

    Always prefer calling a tool over describing what you would do.
    When you call an action tool, always include a short `rationale` saying why.
    """
  end
end
