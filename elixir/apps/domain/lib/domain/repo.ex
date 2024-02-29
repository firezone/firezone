defmodule Domain.Repo do
  use Ecto.Repo,
    otp_app: :domain,
    adapter: Ecto.Adapters.Postgres

  alias Domain.Repo.{Paginator, Preloader, Query}
  require Ecto.Query

  @doc """
  Returns `true` when binary representation of `Ecto.UUID` is valid, otherwise - `false`.
  """
  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false

  @doc """
  Similar to `Ecto.Repo.one/2`, fetches a single result from the query.

  Returns `{:ok, schema}` or `{:error, :not_found}` if no result was found.

  Raises when the query returns more than one row.
  """
  @spec fetch(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [{:preload, term()}]
            | Keyword.t()
        ) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def fetch(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])

    if schema = __MODULE__.one(queryable, opts) do
      {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
      schema = __MODULE__.preload(schema, ecto_preloads)
      {:ok, schema}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Alias of `Ecto.Repo.one!/2` added for naming convenience.
  """
  @spec fetch!(
          queryable :: Ecto.Queryable.t(),
          opts ::
            [{:preload, term()}]
            | Keyword.t()
        ) ::
          Ecto.Schema.t()
  def fetch!(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])

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
  @type after_commit :: (term() -> :ok) | (term(), Ecto.Changeset.t() -> :ok)

  @typedoc """
  A callback which takes a schema and returns a changeset that is then used to update the schema.
  """
  @type changeset_fun :: (term() -> Ecto.Changeset.t())

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
              {:with, changeset_fun()},
              {:preload, term()},
              {:after_callback, after_commit() | [after_commit()]}
            ]
            | Keyword.t()
        ) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def fetch_and_update(queryable, query_module, opts) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {after_commit, opts} = Keyword.pop(opts, :after_commit, [])
    {changeset_fun, repo_shared_opts} = Keyword.pop!(opts, :with)

    queryable = Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")

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

  defp execute_after_commit(schema, changeset, after_commit) do
    after_commit
    |> List.wrap()
    |> Enum.each(fn
      callback when is_function(callback, 1) ->
        :ok = callback.(schema)

      callback when is_function(callback, 2) ->
        :ok = callback.(schema, changeset)
    end)
  end

  defp execute_preloads(schema, query_module, preload) do
    {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
    __MODULE__.preload(schema, ecto_preloads)
  end

  @doc """
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but returns a tuple
  and allow to execute preloads and paginate through the results.
  """
  @spec list(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts ::
            [
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
          | {:error, term()}
  def list(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    # {filters, opts} = Keyword.pop(opts, :filters, %{})

    # Pagination
    {paginator_opts, opts} = Keyword.pop(opts, :page, [])

    with {:ok, paginator_opts} <- Paginator.init(query_module, paginator_opts) do
      {results, metadata} =
        queryable
        |> Paginator.query(paginator_opts)
        |> __MODULE__.all(opts)
        |> Paginator.metadata(paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = __MODULE__.preload(results, ecto_preloads)

      {:ok, results, metadata}
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
