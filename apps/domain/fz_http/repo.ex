defmodule FzHttp.Repo do
  use Ecto.Repo,
    otp_app: :fz_http,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Similar to `Ecto.Repo.one/2`, fetches a single result from the query.

  Returns `{:ok, schema}` or `{:error, :not_found}` if no result was found.
  Raises if there is more than one row matching the query.
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
  Similar to `Ecto.Repo.all/2`, fetches all results from the query but return a tuple.
  """
  def list(queryable, opts \\ []) do
    {:ok, __MODULE__.all(queryable, opts)}
  end
end
