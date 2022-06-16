defmodule FzHttp.OIDC.RefreshManager do
  @moduledoc """
  Manager module for refreshing OIDC connections
  """
  use GenServer, restart: :permanent

  import Ecto.Query
  alias FzHttp.{Repo, Users.User}

  # Refresh every 10 minutes -- Keycloak's ttl for refresh tokens
  # is 30 minutes by default.
  @spawn_interval 10 * 60 * 1000
  @max_delay_after_spawn 15

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

    from(u in User, where: is_nil(u.disabled_at))
    |> Repo.all()
    |> Enum.each(&do_spawn/1)
  end

  defp do_spawn(%{id: id} = _user) do
    delay_after_spawn = Enum.random(1..@max_delay_after_spawn) * 1000

    DynamicSupervisor.start_child(
      FzHttp.RefresherSupervisor,
      {FzHttp.OIDC.Refresher, {id, delay_after_spawn}}
    )
  end
end
