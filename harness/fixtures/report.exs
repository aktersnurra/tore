# What a household's week and memory look like now, the same for either arm of a comparison:
#
#     TORE_DEV_DB=/path/to/copy.db mix run harness/fixtures/report.exs [sub]

sub = List.first(System.argv()) || "harness-berg"
user = Tore.Repo.get_by!(Tore.Accounts.User, oidc_sub: sub)
{_user, scope} = Tore.Accounts.get_session(user.id)
{:ok, context} = Tore.Mcp.Tools.GetContext.call(scope, %{})

IO.puts("NEXT WEEK")

for slot <- context.next_week,
    do: IO.puts("  #{slot.date} #{slot.status} #{Map.get(slot, :recipe_title) || ""}")

IO.puts("\nMEMORY\n#{context.memory || "(empty)"}")

# The fixture's recipes have no source, so these are the ones found on the web.
IO.puts("\nRECIPES FROM THE WEB")

for recipe <- Tore.Recipes.list(scope), recipe.source_url do
  recipe = Tore.Repo.preload(recipe, recipe_ingredients: :ingredient)
  names = Enum.map_join(recipe.recipe_ingredients, ", ", & &1.ingredient.name)
  IO.puts("  #{recipe.title} (#{recipe.recipe_type}) #{recipe.source_url}\n    #{names}")
end

IO.puts("\nLLM SPEND THIS MONTH (server's model): $#{Tore.Costs.llm_spend_this_month(scope)}")
