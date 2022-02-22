defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Repo, Tunnels, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView
  def mount(%{"id" => user_id} = _params, _session, socket) do
    user = Users.get_user!(user_id)

    {:ok,
     socket
     |> assign(:tunnels, Tunnels.list_tunnels(user))
     |> assign(:user, user)
     |> assign(:page_title, "Users")}
  end

  @doc """
  Called when a modal is dismissed; reload tunnels.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    tunnels = Tunnels.list_tunnels(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:tunnels, tunnels)}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Use the account section to delete your account.")}
    else
      user = Users.get_user!(user_id) |> Repo.preload(:tunnels)

      case Users.delete_user(user) do
        {:ok, _} ->
          for tunnel <- user.tunnels, do: @events_module.delete_tunnel(tunnel)
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
end
