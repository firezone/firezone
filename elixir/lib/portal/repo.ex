defmodule Portal.Repo do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query, warn: false

  alias Portal.Authentication.Subject
  alias Portal.Authorization
  alias Portal.Repo.{Paginator, Preloader, Filter}
  require Ecto.Query

  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false

  # ---------------------------------------------------------------------------
  # prepare_query callback - automatically applies account filtering
  # when a subject is set via Authorization.with_subject/2
  # ---------------------------------------------------------------------------

  @doc false
  def prepare_query(_operation, query, opts) do
    case Authorization.current_subject() do
      nil ->
        {query, opts}

      %Subject{account: %{id: account_id}} = subject ->
        schema = get_schema_module(query)

        case Authorization.authorize(:read, schema, subject) do
          :ok ->
            {apply_account_filter(query, schema, account_id), opts}

          {:error, :unauthorized} ->
            {where(query, false), opts}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Subject-aware query wrappers
  #
  # Convenience functions used at call sites. The `fetch/3` and `fetch!/3`
  # variants wrap in Authorization.with_subject/2 automatically.
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a single result or all results, with optional subject-based authorization.

  ## Examples

      # Inside with_subject (subject already in process dict):
      query |> Repo.fetch(:one)
      query |> Repo.fetch(:all)

      # With explicit subject (wraps in with_subject automatically):
      query |> Repo.fetch(:one, subject)
      query |> Repo.fetch(:all, subject)
  """
  def fetch(queryable, :one), do: one(queryable)
  def fetch(queryable, :all), do: all(queryable)

  def fetch(queryable, :one, %Subject{} = subject) do
    Authorization.with_subject(subject, fn -> one(queryable) end)
  end

  def fetch(queryable, :all, %Subject{} = subject) do
    Authorization.with_subject(subject, fn -> all(queryable) end)
  end

  def fetch(queryable, :aggregate, aggregate_type) do
    aggregate(queryable, aggregate_type)
  end

  @doc """
  Fetches a single result, raising on not found.

  ## Examples

      # Inside with_subject:
      query |> Repo.fetch!(:one)

      # With explicit subject:
      query |> Repo.fetch!(subject, :one)
  """
  def fetch!(queryable, :one), do: one!(queryable)

  def fetch!(queryable, %Subject{} = subject, :one) do
    Authorization.with_subject(subject, fn -> one!(queryable) end)
  end

  @doc """
  Fetches results without subject authorization (unscoped).

  ## Examples

      query |> Repo.fetch_unscoped(:one)
      query |> Repo.fetch_unscoped(:all)
      query |> Repo.fetch_unscoped(:aggregate, :count)
  """
  def fetch_unscoped(queryable, :one), do: one(queryable)
  def fetch_unscoped(queryable, :all), do: all(queryable)
  def fetch_unscoped!(queryable, :one), do: one!(queryable)

  def fetch_unscoped(queryable, :aggregate, aggregate_type),
    do: aggregate(queryable, aggregate_type)

  @doc """
  Checks if any results exist, with subject-based authorization.

  ## Examples

      query |> Repo.exists_scoped?(subject)
  """
  def exists_scoped?(queryable, %Subject{} = subject) do
    Authorization.with_subject(subject, fn -> exists?(queryable) end)
  end

  # ---------------------------------------------------------------------------
  # Subject-aware list (pagination)
  # ---------------------------------------------------------------------------

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

  @doc """
  List with explicit subject context for authorization.

  Wraps the list operation in `Authorization.with_subject/2`.
  """
  def list(queryable, %Subject{} = subject, query_module, opts) do
    Authorization.with_subject(subject, fn -> list(queryable, query_module, opts) end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def get_schema_module(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  def get_schema_module(%Ecto.Changeset{data: data}), do: get_schema_module(data)
  def get_schema_module(struct) when is_struct(struct), do: struct.__struct__
  def get_schema_module(module) when is_atom(module), do: module
  def get_schema_module(_), do: nil

  defp apply_account_filter(queryable, Portal.Account, account_id) do
    where(queryable, [x], x.id == ^account_id)
  end

  defp apply_account_filter(queryable, nil, _account_id) do
    queryable
  end

  defp apply_account_filter(queryable, schema, account_id) do
    if is_atom(schema) and :account_id in schema.__schema__(:fields) do
      where(queryable, [x], x.account_id == ^account_id)
    else
      queryable
    end
  end
end
