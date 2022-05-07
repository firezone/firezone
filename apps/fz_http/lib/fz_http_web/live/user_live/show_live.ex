defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  XXX: Admin only
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Repo, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView
  def mount(%{"id" => user_id} = _params, _session, socket) do
    user = Users.get_user!(user_id)
    devices = Devices.list_devices(user)

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:device_config, socket.assigns[:device_config])
     |> assign(:user, user)
     |> assign(:page_title, "Users")}
  end

  @doc """
  Called when a modal is dismissed; reload devices.
  """
  @impl Phoenix.LiveView
  def handle_params(%{"id" => user_id} = _params, _url, socket) do
    user = Users.get_user!(user_id)
    devices = Devices.list_devices(user.id)

    {:noreply,
     socket
     |> assign(:devices, devices)}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Use the account section to delete your account.")}
    else
      user = Users.get_user!(user_id) |> Repo.preload(:devices)

      case Users.delete_user(user) do
        {:ok, _} ->
          for device <- user.devices, do: @events_module.delete_device(device)
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

          {:noreply,
           socket
           |> put_flash(:info, "User deleted successfully.")
           |> push_redirect(to: Routes.user_index_path(socket, :index))}

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
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Changing your own role is not supported.")}
    else
      user = Users.get_user!(user_id)

      role =
        case action do
          "promote" -> :admin
          "demote" -> :unprivileged
        end

      case Users.update_user(user, %{role: role}) do
        {:ok, user} ->
          # Force reconnect with new role
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

          {:noreply,
           socket
           |> assign(:user, user)
           |> put_flash(:info, "User updated successfully.")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Error updating user: #{ErrorHelpers.aggregated_errors(changeset)}"
           )}
      end
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
