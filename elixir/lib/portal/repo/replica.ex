defmodule Portal.Repo.Replica do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true

  alias Portal.Repo.{List, Paginator}

  @spec list(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          opts :: Keyword.t()
        ) ::
          {:ok, [Ecto.Schema.t()], Paginator.Metadata.t()}
          | {:error, :invalid_cursor}
          | {:error, {:unknown_filter, metadata :: Keyword.t()}}
          | {:error, {:invalid_type, metadata :: Keyword.t()}}
          | {:error, {:invalid_value, metadata :: Keyword.t()}}
          | {:error, term()}
  def list(queryable, query_module, opts \\ []) do
    List.call(__MODULE__, queryable, query_module, opts)
  end
end
