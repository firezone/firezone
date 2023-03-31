defmodule FzHttpWeb.NotificationChannel do
  @moduledoc """
  Handles dispatching realtime notifications to users' browser sessions.
  """
  use FzHttpWeb, :channel
  alias FzHttp.Users
  alias FzHttpWeb.Presence

  @impl Phoenix.Channel
  def join("notification:session", _attrs, socket) do
    socket = FzHttpWeb.Sandbox.allow_channel_sql_sandbox(socket)

    with {:ok, user} <- Users.fetch_user_by_id(socket.assigns.current_user_id) do
      socket = assign(socket, :current_user, user)
      send(self(), :after_join)
      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    track(socket)
    {:noreply, socket}
  end

  defp track(socket) do
    user = socket.assigns.current_user

    tracking_info = %{
      email: user.email,
      online_at: DateTime.utc_now(),
      last_signed_in_at: user.last_signed_in_at,
      last_signed_in_method: user.last_signed_in_method,
      remote_ip: socket.assigns.remote_ip,
      user_agent: socket.assigns.user_agent
    }

    {:ok, _} = Presence.track(socket, user.id, tracking_info)

    push(socket, "presence_state", presence_list(socket))
  end

  defp presence_list(socket) do
    ids_to_show = [socket.assigns.current_user.id]

    Presence.list(socket)
    |> Map.take(ids_to_show)
  end
end
