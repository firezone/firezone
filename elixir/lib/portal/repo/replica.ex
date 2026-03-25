defmodule Portal.Repo.Replica do
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres,
    read_only: true

  alias Portal.Repo.{List, Paginator}

  defoverridable get_dynamic_repo: 0

  def get_dynamic_repo do
    case Process.get({__MODULE__, :dynamic_repo}) do
      nil ->
        repo = Portal.Repo.DynamicRepoResolver.inherit(__MODULE__)
        if repo != __MODULE__, do: put_dynamic_repo(repo)
        repo

      repo ->
        repo
    end
  end

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
