defmodule Portal.Repo.List do
  @moduledoc false

  alias Portal.Repo.{Paginator, Preloader, Filter}

  def call(repo, queryable, query_module, opts) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {order_by, opts} = Keyword.pop(opts, :order_by, [])
    {paginator_opts, opts} = Keyword.pop(opts, :page, [])

    with {:ok, paginator_opts} <- Paginator.init(query_module, order_by, paginator_opts),
         {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      count = repo.aggregate(queryable, :count, :id)

      {results, metadata} =
        queryable
        |> Paginator.query(paginator_opts)
        |> repo.all(opts)
        |> Paginator.metadata(paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = repo.preload(results, ecto_preloads)

      {:ok, results, %{metadata | count: count}}
    end
  end
end
