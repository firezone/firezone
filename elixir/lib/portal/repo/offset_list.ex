defmodule Portal.Repo.OffsetList do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Portal.Repo.{OffsetPaginator, Preloader, Filter}

  @doc """
  Pass `:statement_timeout` (milliseconds) to bound the total time spent in
  PostgreSQL. PostgreSQL cancels the running statement once the budget is used
  up and `{:error, :query_timeout}` is returned, so the connection survives.
  Pass `:timeout` as well to raise the DBConnection checkout deadline above
  that budget.
  """
  def call(repo, queryable, query_module, opts) do
    {statement_timeout, opts} = Keyword.pop(opts, :statement_timeout)
    {timeout, opts} = Keyword.pop(opts, :timeout)
    {count_limit, opts} = Keyword.pop(opts, :count_limit)
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {order_by, opts} = Keyword.pop(opts, :order_by, [])
    {paginator_opts, opts} = Keyword.pop(opts, :page, [])
    {limit, opts} = Keyword.pop(opts, :limit)
    {order_by_nulls, opts} = Keyword.pop(opts, :order_by_nulls, :last)

    paginator_opts =
      if limit do
        Keyword.put_new(paginator_opts, :limit, limit)
      else
        paginator_opts
      end

    paginator_opts = Keyword.put(paginator_opts, :order_by_nulls, order_by_nulls)

    with {:ok, paginator_opts} <- OffsetPaginator.init(query_module, order_by, paginator_opts),
         {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      within_budget(repo, statement_timeout, timeout, fn tune ->
        fetch(repo, queryable, query_module, tune, %{
          paginator_opts: paginator_opts,
          preload: preload,
          count_limit: count_limit,
          opts: opts
        })
      end)
    end
  end

  defp fetch(repo, queryable, query_module, tune, params) do
    %{paginator_opts: paginator_opts, preload: preload, count_limit: count_limit, opts: opts} =
      params

    # Ecto aggregates a limited query through a subquery, so LIMIT bounds
    # the rows counted rather than the single aggregate result.
    count_query =
      if count_limit do
        queryable |> exclude(:order_by) |> limit(^count_limit)
      else
        queryable
      end

    tune.()
    count = repo.aggregate(count_query, :count)

    tune.()

    {results, metadata} =
      queryable
      |> OffsetPaginator.query(paginator_opts)
      |> repo.all(opts)
      |> OffsetPaginator.metadata(paginator_opts)

    {results, ecto_preloads} = Preloader.preload(results, preload, query_module)

    tune.()
    results = repo.preload(results, ecto_preloads)

    {:ok, results,
     %{metadata | count: count, count_limited: not is_nil(count_limit) and count >= count_limit}}
  end

  defp within_budget(_repo, nil, _timeout, fun), do: fun.(fn -> :ok end)

  defp within_budget(repo, statement_timeout, timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + statement_timeout

    # The statement timeout is set per statement from what is left of the
    # budget, so the statements together stay inside it.
    tune = fn ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)
      repo.query!("SELECT set_config('statement_timeout', $1, true)", [to_string(remaining)])
      :ok
    end

    {:ok, result} =
      repo.transaction(fn -> fun.(tune) end, timeout: timeout || statement_timeout + 5_000)

    result
  rescue
    error in Postgrex.Error ->
      if match?(%{postgres: %{code: :query_canceled}}, error) do
        Logger.warning("Offset list query timed out",
          statement_timeout: statement_timeout,
          query: error.query
        )

        {:error, :query_timeout}
      else
        reraise error, __STACKTRACE__
      end
  end
end
