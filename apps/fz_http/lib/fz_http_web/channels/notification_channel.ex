defmodule FzHttpWeb.NotificationChannel do
  @moduledoc """
  Handles dispatching realtime notifications to users' browser sessions.
  """
  use FzHttpWeb, :channel
  import FzCommon.FzNet, only: [convert_ip: 1]
  alias FzHttp.Users
  alias FzHttpWeb.Presence

  @token_verify_opts [max_age: 86_400]

  @impl Phoenix.Channel
  def join("notification:session", %{"user_agent" => user_agent, "token" => token}, socket) do
    case Phoenix.Token.verify(socket, "channel auth", token, @token_verify_opts) do
      {:ok, user_id} ->
        socket =
          socket
          |> assign(:current_user, Users.get_user!(user_id))
          |> assign(:user_agent, user_agent)

        send(self(), :after_join)

        {:ok,
         socket
         |> assign(:current_user, Users.get_user!(user_id))}

      {:error, _} ->
        {:error, %{reason: "unauthorized"}}
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
      remote_ip: convert_ip(socket.assigns.remote_ip),
      user_agent: socket.assigns.user_agent
    }

    {:ok, _} = Presence.track(socket, user.id, tracking_info)

    push(socket, "presence_state", presence_list(socket))
  end

  defp presence_list(socket) do
    ids_to_show = [Integer.to_string(socket.assigns.current_user.id)]

    Presence.list(socket)
    |> Map.take(ids_to_show)
  end
end
