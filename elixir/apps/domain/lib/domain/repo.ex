defmodule Domain.Repo do
  use Ecto.Repo,
    otp_app: :domain,
    adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @doc """
  Similar to `Ecto.Repo.one/2`, fetches a single result from the query.

  Returns `{:ok, schema}` or `{:error, :not_found}` if no result was found.

  Raises when the query returns more than one row.
  """
  @spec fetch(queryable :: Ecto.Queryable.t(), opts :: Keyword.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def fetch(queryable, opts \\ []) do
    case __MODULE__.one(queryable, opts) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  @doc """
  Alias of `Ecto.Repo.one!/2` added for naming convenience.
  """
  def fetch!(queryable, opts \\ []), do: __MODULE__.one!(queryable, opts)

  @doc """
  Uses query to fetch a single result from the database, locks it for update and
  then updates it using a changeset within a database transaction.

  Raises when the query returns more than one row.
  """
  @spec fetch_and_update(
          queryable :: Ecto.Queryable.t(),
          [{:with, changeset_fun :: (term() -> Ecto.Changeset.t())}],
          opts :: Keyword.t()
        ) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def fetch_and_update(queryable, [with: changeset_fun], opts \\ [])
      when is_function(changeset_fun, 1) do
    transaction(fn ->
      queryable = Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")

      with {:ok, schema} <- fetch(queryable, opts) do
        schema
        |> changeset_fun.()
        |> case do
          {%Ecto.Changeset{} = changeset, execute_after_commit: cb} when is_function(cb, 1) ->
            {update(changeset, mode: :savepoint), cb}

          %Ecto.Changeset{} = changeset ->
            {update(changeset, mode: :savepoint), nil}

          reason ->
            {:error, reason}
        end
      end
    end)
    |> case do
      {:ok, {{:ok, schema}, nil}} ->
        {:ok, schema}

      {:ok, {{:ok, schema}, cb}} ->
        cb.(schema)
        {:ok, schema}

      {:ok, {{:error, reason}, _cb}} ->
        {:error, reason}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but return a tuple.
  """
  def list(queryable, opts \\ []) do
    {:ok, __MODULE__.all(queryable, opts)}
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
  def counts(queryable, ids) do
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
