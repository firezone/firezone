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

  @impl GenServer
  def handle_info({:notification, _pid, _ref, event, payload}, _state) do
    subject = String.split(event, "_") |> List.first()
    data = Jason.decode!(payload, keys: :atoms)

    handle_event(subject, data)

    {:noreply, :event_handled}
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def handle_event(subject, %{op: "INSERT"} = data) do
    Events.add(subject, data.row)
  end

  def handle_event(subject, %{op: "DELETE"} = data) do
    Events.delete(subject, data.row)
  end
end
