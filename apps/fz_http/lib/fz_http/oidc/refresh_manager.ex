defmodule FzHttp.OIDC.RefreshManager do
  @moduledoc """
  Manager module for refreshing OIDC connections
  """
  use GenServer, restart: :permanent

  alias FzHttp.{Repo, Users.User}

  @spawn_interval 60 * 60 * 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    {:ok, [], {:continue, :schedule}}
  end

  def handle_continue(:schedule, state) do
    spawn_refresher()
    {:noreply, state}
  end

  def handle_info(:spawn_refresher, user_id) do
    spawn_refresher()
    {:noreply, user_id}
  end

  defp schedule do
    Process.send_after(self(), :spawn_refresher, @spawn_interval)
  end

  defp spawn_refresher do
    schedule()

    User
    |> Repo.all()
    |> Enum.each(&do_spawn/1)
  end

  defp do_spawn(%{id: id} = _user) do
    DynamicSupervisor.start_child(FzHttp.RefresherSupervisor, {FzHttp.OIDC.Refresher, id})
  end
end
