defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  XXX: Admin only
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Auth.OIDC, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView

  def mount(%{"id" => user_id} = _params, _session, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)
    connections = OIDC.list_connections(user)

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:device_config, socket.assigns[:device_config])
     |> assign(:connections, connections)
     |> assign(:user, user)
     |> assign(:page_title, "Users")
     |> assign(:rules_path, ~p"/rules")}
  end

  @doc """
  Called when a modal is dismissed; reload devices.
  """
  @impl Phoenix.LiveView
  def handle_params(%{"id" => user_id} = _params, _url, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)

    socket =
      socket
      |> assign(:devices, devices)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Use the account section to delete your account.")}
    else
      {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)

      case Users.delete_user(user, socket.assigns.subject) do
        {:ok, _} ->
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

          {:noreply,
           socket
           |> put_flash(:info, "User deleted successfully.")
           |> push_redirect(to: ~p"/users")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Error deleting user: #{ErrorHelpers.aggregated_errors(changeset)}"
           )}
      end
    end
  end

  @impl Phoenix.LiveView
  def handle_event(action, %{"user_id" => user_id}, socket) when action in ~w(promote demote) do
    role =
      case action do
        "promote" -> :admin
        "demote" -> :unprivileged
      end

    with {:ok, user} <- Users.fetch_user_by_id(user_id, socket.assigns.subject),
         {:ok, user} <- Users.update_user(user, %{role: role}, socket.assigns.subject) do
      # Force reconnect with new role
      FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

      socket =
        socket
        |> assign(:user, user)
        |> put_flash(:info, "User updated successfully.")

      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        message = "Error, #{ErrorHelpers.aggregated_errors(changeset)}"
        socket = put_flash(socket, :error, message)
        {:noreply, socket}

      {:error, reason} ->
        message = "Error updating user: #{inspect(reason)}"
        socket = put_flash(socket, :error, message)
        {:noreply, socket}
    end
  end

  @action_and_message %{
    admin: %{
      action: "demote",
      message: "This will remove admin permissions from the user."
    },
    unprivileged: %{
      action: "promote",
      message: "This will give admin permissions to the user."
    }
  }

  defp mote(%{role: role}) do
    @action_and_message[role].action
  end

  defp mote_message(%{role: role}) do
    @action_and_message[role].message
  end
end
