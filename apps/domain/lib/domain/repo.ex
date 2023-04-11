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
          {:ok, Ecto.Schema.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def fetch_and_update(queryable, [with: changeset_fun], opts \\ [])
      when is_function(changeset_fun, 1) do
    transaction(fn ->
      queryable = Ecto.Query.lock(queryable, "FOR UPDATE")

      with {:ok, schema} <- fetch(queryable, opts) do
        schema
        |> changeset_fun.()
        |> update(opts)
      end
    end)
    |> case do
      {:ok, {:ok, schema}} -> {:ok, schema}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but return a tuple.
  """
  def list(queryable, opts \\ []) do
    {:ok, __MODULE__.all(queryable, opts)}
  end
end
