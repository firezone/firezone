defmodule Portal.Oban do
  @moduledoc """
  Supervises Oban with its configured Repo as the dynamic Repo for all workers.

  Oban uses its `:repo` option for internal job storage, but domain code called
  from `c:Oban.Worker.perform/1` uses `Portal.Repo`. Storing the configured Repo
  on this supervisor lets `Portal.Repo.DynamicRepoResolver` route all descendant
  worker queries to the same isolated job pool.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Portal.Repo.put_dynamic_repo(Keyword.fetch!(opts, :repo))

    Supervisor.init([{Oban, opts}], strategy: :one_for_one)
  end
end
