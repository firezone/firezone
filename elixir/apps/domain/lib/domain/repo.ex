defmodule Domain.Repo do
  use Ecto.Repo,
    otp_app: :domain,
    adapter: Ecto.Adapters.Postgres

  alias Domain.Repo.{Paginator, Preloader, Filter}
  require Ecto.Query

  @doc """
  Returns `true` when binary representation of `Ecto.UUID` is valid, otherwise - `false`.
  """
  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false

  @doc """
  Similar to `Ecto.Repo.one/2`, fetches a single result from the query
  but supports custom preloads and filters.

  Returns `{:ok, schema}` or `{:error, :not_found}` if no result was found.

  Raises when the query returns more than one row.
  """
  @spec fetch(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:preload, term()}
              | {:filter, Domain.Repo.Filter.filters()}
            ]
            | Keyword.t()
        ) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, {:unknown_filter, metadata :: Keyword.t()}}
          | {:error, {:invalid_type, metadata :: Keyword.t()}}
          | {:error, {:invalid_value, metadata :: Keyword.t()}}
  def fetch(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter),
         schema when not is_nil(schema) <- __MODULE__.one(queryable, opts) do
      {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
      schema = __MODULE__.preload(schema, ecto_preloads)
      {:ok, schema}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Alias of `Ecto.Repo.one!/2` that supports preloads and filters.
  """
  @spec fetch!(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:preload, term()}
              | {:filter, Domain.Repo.Filter.filters()}
            ]
            | Keyword.t()
        ) :: Ecto.Schema.t() | term() | no_return()
  def fetch!(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])

    {:ok, queryable} = Filter.filter(queryable, query_module, filter)
    schema = __MODULE__.one!(queryable, opts)
    {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
    __MODULE__.preload(schema, ecto_preloads)
  end

  @typedoc """
  A callback which is executed after the transaction is committed.

  The callback is either a function that takes the schema as an argument or
  a function that takes the schema and the changeset as arguments.

  It must return `:ok`.
  """
  @type update_after_commit :: (term() -> :ok) | (term(), Ecto.Changeset.t() -> :ok)

  @typedoc """
  A callback which takes a schema and returns a changeset that is then used to update the schema.
  """
  @type fetch_and_update_changeset_fun :: (term() -> Ecto.Changeset.t())

  @doc """
  Uses query to fetch a single result from the database, locks it for update and
  then updates it using a changeset within a database transaction.

  Raises when the query returns more than one row.
  """
  @spec fetch_and_update(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:with, fetch_and_update_changeset_fun()}
              | {:preload, term()}
              | {:filter, Domain.Repo.Filter.filters()}
              | {:after_callback, update_after_commit() | [update_after_commit()]}
            ]
            | Keyword.t()
        ) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, {:unknown_filter, metadata :: Keyword.t()}}
          | {:error, {:invalid_type, metadata :: Keyword.t()}}
          | {:error, {:invalid_value, metadata :: Keyword.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def fetch_and_update(queryable, query_module, opts) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {after_commit, opts} = Keyword.pop(opts, :after_commit, [])
    {changeset_fun, repo_shared_opts} = Keyword.pop!(opts, :with)

    queryable = Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      fn ->
        if schema = __MODULE__.one(queryable, repo_shared_opts) do
          case changeset_fun.(schema) do
            %Ecto.Changeset{} = changeset ->
              {update(changeset, mode: :savepoint), changeset}

            reason ->
              {:error, reason}
          end
        else
          {:error, :not_found}
        end
      end
      |> transaction(repo_shared_opts)
      |> case do
        {:ok, {{:ok, schema}, changeset}} ->
          :ok = execute_after_commit(schema, changeset, after_commit)
          {:ok, execute_preloads(schema, query_module, preload)}

        {:ok, {{:error, reason}, _changeset}} ->
          {:error, reason}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @typedoc """
  A callback which is executed after the transaction is committed that
  has a breaking change to the record in the database.

  The callback is either a function that takes the schema as an argument or
  a function that takes the schema and the changeset as arguments.

  It must return `:ok`.
  """
  @type break_after_commit :: (updated_schema :: term(), update_changeset :: Ecto.Changeset.t() ->
                                 :ok)

  @typedoc """
  A callback which takes a schema and returns a changeset that is then used to update the schema and a boolean indicating whether the update is a breaking change.
  """
  @type fetch_update_changeset_fun :: (term() ->
                                         {update_changeset :: Ecto.Changeset.t(),
                                          breaking_change :: true | false})

  @doc """
  Uses query to fetch a single result from the database, locks it for update and
  then updates it using a changesets within a database transaction. Different callbacks can
  be used for a breaking change to the record.
  """
  @spec fetch_and_update_breakable(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:with, fetch_update_changeset_fun()}
              | {:preload, term()}
              | {:filter, Domain.Repo.Filter.filters()}
              | {:after_update_commit, update_after_commit() | [update_after_commit()]}
              | {:after_breaking_update_commit, break_after_commit() | [break_after_commit()]}
            ]
            | Keyword.t()
        ) ::
          {:updated, Ecto.Schema.t()}
          | {:breaking_update, Ecto.Schema.t(), Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, {:unknown_filter, metadata :: Keyword.t()}}
          | {:error, {:invalid_type, metadata :: Keyword.t()}}
          | {:error, {:invalid_value, metadata :: Keyword.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def fetch_and_update_breakable(queryable, query_module, opts) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {after_update_commit, opts} = Keyword.pop(opts, :after_update_commit, [])
    {after_breaking_update_commit, opts} = Keyword.pop(opts, :after_breaking_update_commit, [])
    {changeset_fun, transaction_opts} = Keyword.pop!(opts, :with)

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      Ecto.Multi.new()
      |> Ecto.Multi.one(:fetch_and_lock, fn
        _effects_so_far ->
          Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")
      end)
      |> Ecto.Multi.run(:changeset, fn _repo, %{fetch_and_lock: schema} ->
        {%Ecto.Changeset{} = update_changeset, breaking} =
          changeset_fun.(schema)

        {:ok, {update_changeset, breaking}}
      end)
      |> Ecto.Multi.update(:update, fn
        %{changeset: {update_changeset, _breaking}} ->
          update_changeset
      end)
      |> transaction(transaction_opts)
      |> case do
        {:ok, %{update: updated, changeset: {update_changeset, false}}} ->
          :ok = execute_after_commit(updated, update_changeset, after_update_commit)
          {:updated, execute_preloads(updated, query_module, preload)}

        {:ok, %{update: updated, changeset: {update_changeset, true}}} ->
          :ok = execute_after_commit(updated, update_changeset, after_breaking_update_commit)
          {:updated, execute_preloads(updated, query_module, preload)}

        {:error, :fetch_and_lock, reason, _changes_so_far} ->
          {:error, reason}

        {:error, :update, changeset, _changes_so_far} ->
          {:error, changeset}
      end
    end
  end

  defp execute_after_commit(schema_or_tuple, changeset_or_changesets, after_commit) do
    after_commit
    |> List.wrap()
    |> Enum.each(fn
      callback when is_function(callback, 1) ->
        :ok = callback.(schema_or_tuple)

      callback when is_function(callback, 2) ->
        :ok = callback.(schema_or_tuple, changeset_or_changesets)
    end)
  end

  defp execute_preloads(schema, query_module, preload) do
    {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
    __MODULE__.preload(schema, ecto_preloads)
  end

  @doc """
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but returns a tuple
  and allow to execute preloads and paginate through the results.

  # Pagination

  The `:page` option is used to paginate the results. Supported options:
    * `:cursor` to fetch next or previous page. It is returned in the metadata of the previous request;
    *`:limit` is used to limit the number of results returned, default: `50` and maximum is `100`.

  The query module must implement `c:Domain.Repo.Query.cursor_fields/0` callback to define the pagination fields.

  # Ordering

  The `:order_by` option is used to order the results, it extend the pagination fields defined by the query module
  and uses the same format as `t:Domain.Repo.Query.cursor_fields/0`.

  # Preloading

  The `:preload` option is used to preload associations. It works the same way as `Ecto.Repo.preload/2`,
  but certain keys can be overloaded by the query module by implementing `c:Domain.Repo.preloads/0` callback.

  # Filtering

  The `:filter` option is used to filter the results, for more information see `Domain.Repo.Filter` moduledoc.

  The query module must implement `c:Domain.Repo.Query.get_filters/0` callback to define the filters.
  """
  @spec list(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
              {:limit, non_neg_integer()},
              {:order_by, Domain.Repo.Query.cursor_fields()},
              {:filter, Domain.Repo.Filter.filters()},
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
  Peek is used to fetch a preview of the a association for each of schemas.

  It takes list of schemas and queryable which is used to preload a few assocs along with
  total count of assocs available as `%{id: schema.id, count: schema_counts.count, item: assocs}` map.
  """
  def peek(queryable, schemas) do
    ids = schemas |> Enum.map(& &1.id) |> Enum.uniq()
    preview = Map.new(ids, fn id -> {id, %{count: 0, items: []}} end)

    preview =
      queryable
      |> all()
      |> Enum.group_by(&{&1.id, &1.count}, & &1.item)
      |> Enum.reduce(preview, fn {{id, count}, items}, acc ->
        Map.put(acc, id, %{count: count, items: items})
      end)

    {:ok, preview}
  end

  @doc """
  Similar to `peek/2` but only returns count of assocs.
  """
  def peek_counts(queryable, ids) do
    ids = Enum.uniq(ids)
    preview = Map.new(ids, fn id -> {id, 0} end)

    preview =
      queryable
      |> all()
      |> Enum.reduce(preview, fn %{id: id, count: count}, acc ->
        Map.put(acc, id, count)
      end)

    {:ok, preview}
  end
end
