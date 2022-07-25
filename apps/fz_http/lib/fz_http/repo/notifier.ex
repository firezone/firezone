defmodule FzHttp.Repo.Notifier do
  @moduledoc """
  Listens for Repo notifications and trigger events based on data changes.
  """

  use GenServer

  alias FzHttp.Events
  alias FzHttp.Repo

  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(state) do
    for subject <- ~w(devices rules users)a do
      {:ok, _ref} = Postgrex.Notifications.listen(Repo.Notifications, "#{subject}_changed")
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:notification, _pid, _ref, event, payload}, _state) do
    data = Jason.decode!(payload, keys: :atoms)
    subject = String.split(event, "_") |> List.first()

    handle_event(subject, data)

    {:noreply, :event_handled}
  end

  defp handle_event(subject, %{op: "INSERT"} = data) do
    Events.add(subject, data.row)
  end

  defp handle_event(subject, %{op: "DELETE"} = data) do
    Events.delete(subject, data.row)
  end
end
