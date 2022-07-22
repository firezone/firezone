defmodule FzHttp.Repo.Notifier do
  @moduledoc """
  Listens for Repo notifications and trigger events based on data changes.
  """

  use GenServer

  alias FzHttp.Events
  alias FzHttp.Repo
  alias Postgrex.Notifications

  require Logger

  @devices_changed_event "devices_changed"
  @rules_changed_event "rules_changed"
  @users_changed_event "users_changed"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    with {:ok, _ref} <- Notifications.listen(Repo.Notifications, @devices_changed_event),
         {:ok, _ref} <- Notifications.listen(Repo.Notifications, @rules_changed_event),
         {:ok, _ref} <- Notifications.listen(Repo.Notifications, @users_changed_event) do
      {:ok, opts}
    else
      error -> {:stop, error}
    end
  end

  @impl GenServer
  def handle_info({:notification, _pid, _ref, event, payload}, _state) do
    data = Jason.decode!(payload, keys: :atoms)

    handle_event(event, data)

    {:noreply, :event_handled}
  end

  defp handle_event(@devices_changed_event, data) do
    case data.op do
      "INSERT" -> Events.add_device(data.row)
      "DELETE" -> Events.delete_device(data.row)
    end
  end

  defp handle_event(@rules_changed_event, data) do
    case data.op do
      "INSERT" -> Events.add_rule(data.row)
      "DELETE" -> Events.delete_rule(data.row)
    end
  end

  defp handle_event(@users_changed_event, data) do
    case data.op do
      "INSERT" -> Events.create_user(data.row)
      "DELETE" -> Events.delete_user(data.row)
    end
  end
end
