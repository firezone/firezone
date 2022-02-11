defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Repo, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign_defaults(params, session, &load_data/2)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
  def handle_event("create_device", %{"device" => device_params}, socket) do
    case Devices.create_device(device_params) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> put_flash(:info, "Device created successfully.")
         |> redirect(to: Routes.device_show_path(socket, :show, device))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Error creating device: #{ErrorHelpers.aggregated_errors(changeset)}"
         )}
    end
  end

  defp load_data(params, socket) do
    user = Users.get_user!(params["id"])

    if socket.assigns.current_user.role == :admin do
      socket
      |> assign(:devices, Devices.list_devices(user))
      |> assign(:user, user)
    else
      not_authorized(socket)
    end
  end
end
