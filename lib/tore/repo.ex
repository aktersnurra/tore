defmodule Tore.Repo do
  @moduledoc """
  The repo, with a guard that keeps each household's rows to itself.

  A query that touches a household table needs a `household_id:` option (see `Tore.Scope.repo_opts/1`).
  With one, every household table the query reads gets filtered to that household: the root and joins,
  and the same again inside subqueries, unions and CTEs. Joins are filtered in their `on`, so a left join
  keeps its rows. Without one, the query raises, so a call site that forgets the scope crashes instead of
  reading another household's rows.

  Not covered: inserts and struct updates and deletes (the scope sets `household_id`, and `NOT NULL`
  catches a miss), raw SQL through `query/3` and fragments, and preloads, which follow foreign keys from
  rows a scoped query already returned.
  """

  use Ecto.Repo,
    otp_app: :tore,
    adapter: Ecto.Adapters.SQLite3

  alias Ecto.Query.{BooleanExpr, JoinExpr}

  # Grows as each context takes a scope.
  @household_tables MapSet.new(
                      ~w(uploaded_images recipes ingredients tags pantry_items events week_modes receipts dining_out prep_guides household_preferences household_insights)
                    )

  @doc false
  def household_tables, do: @household_tables

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:ecto_query] == :preload ->
        {query, opts}

      household_id = opts[:household_id] ->
        {query |> walk(household_id) |> elem(0), opts}

      table = query |> walk(nil) |> elem(1) |> Enum.find(&guarded?/1) ->
        raise ArgumentError,
              "query on household table #{inspect(table)} without a household_id option"

      true ->
        {query, opts}
    end
  end

  # One pass over the query and everything nested in it. Returns the query with every guarded binding
  # filtered to `household_id` (unchanged when it is nil) and the tables it found.
  defp walk(%Ecto.Query{} = query, household_id) do
    bindings = binding_tables(query)
    {query, nested} = walk_nested(query, household_id)

    query =
      if household_id do
        query
        |> Map.update!(:wheres, fn wheres ->
          if guarded?(hd(bindings)),
            do: wheres ++ [household_filter(0, household_id)],
            else: wheres
        end)
        |> Map.update!(:joins, fn joins ->
          joins
          |> Enum.with_index(1)
          |> Enum.map(fn {join, ix} ->
            if guarded?(Enum.at(bindings, ix)),
              do: filter_join(join, ix, household_id),
              else: join
          end)
        end)
      else
        query
      end

    {query, Enum.reject(bindings, &is_nil/1) ++ nested}
  end

  @expr_lists [:wheres, :havings, :order_bys, :group_bys]

  defp walk_nested(query, household_id) do
    recurse = fn q, acc ->
      {q, tables} = walk(q, household_id)
      {q, tables ++ acc}
    end

    {from, acc} = walk_source(query.from, [], recurse)
    {joins, acc} = Enum.map_reduce(query.joins, acc, &walk_source(&1, &2, recurse))

    {query, acc} =
      Enum.reduce(@expr_lists, {%{query | from: from, joins: joins}, acc}, fn key, {q, acc} ->
        {exprs, acc} = Enum.map_reduce(Map.fetch!(q, key), acc, &walk_subqueries(&1, &2, recurse))
        {Map.put(q, key, exprs), acc}
      end)

    {select, acc} = walk_subqueries(query.select, acc, recurse)

    {combinations, acc} =
      Enum.map_reduce(query.combinations, acc, fn {kind, q}, acc ->
        {q, acc} = recurse.(q, acc)
        {{kind, q}, acc}
      end)

    {with_ctes, acc} =
      case query.with_ctes do
        nil ->
          {nil, acc}

        with_expr ->
          {queries, acc} = Enum.map_reduce(with_expr.queries, acc, &walk_cte(&1, &2, recurse))
          {%{with_expr | queries: queries}, acc}
      end

    {%{query | select: select, combinations: combinations, with_ctes: with_ctes}, acc}
  end

  defp walk_source(%{source: %Ecto.SubQuery{query: q} = sq} = expr, acc, recurse) do
    {q, acc} = recurse.(q, acc)
    {%{expr | source: %{sq | query: q}}, acc}
  end

  defp walk_source(expr, acc, _recurse), do: {expr, acc}

  defp walk_subqueries(%{subqueries: [_ | _] = subqueries} = expr, acc, recurse) do
    {subqueries, acc} =
      Enum.map_reduce(subqueries, acc, fn sq, acc ->
        {q, acc} = recurse.(sq.query, acc)
        {%{sq | query: q}, acc}
      end)

    {%{expr | subqueries: subqueries}, acc}
  end

  defp walk_subqueries(expr, acc, _recurse), do: {expr, acc}

  defp walk_cte({name, opts, %Ecto.Query{} = q}, acc, recurse) do
    {q, acc} = recurse.(q, acc)
    {{name, opts, q}, acc}
  end

  defp walk_cte(cte, acc, _recurse), do: {cte, acc}

  defp household_filter(ix, household_id) do
    %BooleanExpr{
      op: :and,
      expr: {:==, [], [field(ix), {:^, [], [0]}]},
      params: [{household_id, {ix, :household_id}}],
      file: __ENV__.file,
      line: __ENV__.line
    }
  end

  defp filter_join(%JoinExpr{on: on} = join, ix, household_id) do
    condition = {:==, [], [field(ix), {:^, [], [length(on.params)]}]}

    %{
      join
      | on: %{
          on
          | expr: {:and, [], [on.expr, condition]},
            params: on.params ++ [{household_id, {ix, :household_id}}]
        }
    }
  end

  defp field(ix), do: {{:., [], [{:&, [], [ix]}, :household_id]}, [], []}

  defp guarded?(table), do: is_binary(table) and MapSet.member?(@household_tables, table)

  # The table behind each binding: index 0 is `from`, then the joins in order.
  defp binding_tables(%Ecto.Query{from: from, joins: joins}) do
    {_schemas, tables} =
      Enum.reduce([from | joins], {[], []}, fn expr, {schemas, tables} ->
        {schema, table} = binding(expr, schemas)
        {schemas ++ [schema], tables ++ [table]}
      end)

    tables
  end

  defp binding(%{source: {table, schema}}, _schemas) when is_binary(table), do: {schema, table}

  defp binding(%{source: {nil, schema}}, _schemas) when is_atom(schema) and not is_nil(schema),
    do: {schema, schema.__schema__(:source)}

  defp binding(%{assoc: {parent, field}}, schemas) when is_integer(parent) do
    case Enum.at(schemas, parent) do
      nil ->
        {nil, nil}

      parent_schema ->
        case parent_schema.__schema__(:association, field) do
          %{related: related} ->
            {related, related.__schema__(:source)}

          _through ->
            raise ArgumentError,
                  "the household guard can't follow the through association #{inspect(field)}"
        end
    end
  end

  defp binding(_expr, _schemas), do: {nil, nil}
end
