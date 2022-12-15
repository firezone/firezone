defmodule FzHttp.Repo.Notifier do
  @moduledoc """
  Listens for Repo notifications and trigger events based on data changes.
  """

  use GenServer

  alias FzHttp.Events
  alias FzHttp.Repo

  @impl GenServer
  def init(state) do
    for subject <- ~w(devices rules users)a do
      {:ok, _ref} = Postgrex.Notifications.listen(Repo.Notifications, "#{subject}_changed")
    end

    {:ok, state}
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
end
