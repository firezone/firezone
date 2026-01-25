defmodule Portal.Repo do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres

  alias Portal.Repo.{Paginator, Preloader, Filter}
  require Ecto.Query

  def read_only?, do: false

  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false

  @doc """
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but returns a tuple
  and allow to execute preloads and paginate through the results.

  # Pagination

  The `:page` option is used to paginate the results. Supported options:
    * `:cursor` to fetch next or previous page. It is returned in the metadata of the previous request;
    *`:limit` is used to limit the number of results returned, default: `50` and maximum is `100`.

  The query module must implement `c:Portal.Repo.Query.cursor_fields/0` callback to define the pagination fields.

  # Ordering

  The `:order_by` option is used to order the results, it extend the pagination fields defined by the query module
  and uses the same format as `t:Portal.Repo.Query.cursor_fields/0`.

  # Preloading

  The `:preload` option is used to preload associations. It works the same way as `Ecto.Repo.preload/2`,
  but certain keys can be overloaded by the query module by implementing `c:Portal.Repo.preloads/0` callback.

  # Filtering

  The `:filter` option is used to filter the results, for more information see `Portal.Repo.Filter` moduledoc.

  The query module must implement `c:Portal.Repo.Query.get_filters/0` callback to define the filters.
  """
  @spec list(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:limit, non_neg_integer()},
              {:order_by, Portal.Repo.Query.cursor_fields()},
              {:filter, Portal.Repo.Filter.filters()},
              {:preload, term()},
              {:page,
               [
                 {:cursor, binary()},
                 {:limit, non_neg_integer()}
               ]}
            ]
            | Keyword.t()
        ) ::
          {:ok, [Ecto.Schema.t()], Paginator.Metadata.t()}
          | {:error, :invalid_cursor}
          | {:error, {:unknown_filter, metadata :: Keyword.t()}}
          | {:error, {:invalid_type, metadata :: Keyword.t()}}
          | {:error, {:invalid_value, metadata :: Keyword.t()}}
          | {:error, term()}
  def list(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {order_by, opts} = Keyword.pop(opts, :order_by, [])
    {paginator_opts, opts} = Keyword.pop(opts, :page, [])

    with {:ok, paginator_opts} <- Paginator.init(query_module, order_by, paginator_opts),
         {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      count = __MODULE__.aggregate(queryable, :count, :id)

      {results, metadata} =
        queryable
        |> Paginator.query(paginator_opts)
        |> __MODULE__.all(opts)
        |> Paginator.metadata(paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = __MODULE__.preload(results, ecto_preloads)

      {:ok, results, %{metadata | count: count}}
    end
  end
end
