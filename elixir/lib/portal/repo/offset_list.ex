defmodule Portal.Repo.OffsetList do
  @moduledoc false

  import Ecto.Query

  alias Portal.Repo.{OffsetPaginator, Preloader, Filter}

  def call(repo, queryable, query_module, opts) do
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
      # Ecto aggregates a limited query through a subquery, so LIMIT bounds
      # the rows counted rather than the single aggregate result.
      count_query =
        if count_limit do
          queryable |> exclude(:order_by) |> limit(^count_limit)
        else
          queryable
        end

      count = repo.aggregate(count_query, :count)

      {results, metadata} =
        queryable
        |> OffsetPaginator.query(paginator_opts)
        |> repo.all(opts)
        |> OffsetPaginator.metadata(paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = repo.preload(results, ecto_preloads)

      {:ok, results,
       %{metadata | count: count, count_limited: not is_nil(count_limit) and count >= count_limit}}
    end
  end
end
