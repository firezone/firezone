defmodule FgHttpWeb.AccountLive.Show do
  @moduledoc """
  Handles Account-related things.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.Users

  @impl true
  def mount(params, session, socket) do
    {:ok, assign_defaults(params, session, socket, &load_data/2)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
  end

  defp apply_action(socket, :edit, _params) do
    socket
  end

  @impl true
  def handle_event("update_user", %{"user" => user_params}, socket) do
    user = Users.get_user!(socket.assigns.current_user.id)

    case Users.update_user(user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully.")
         |> redirect(to: Routes.account_show_path(socket, :show))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error updating account.")
         |> assign(:changeset, changeset)}
    end
  end

  def handle_event("delete_user", _params, socket) do
    # XXX: Disconnect all WebSockets.
    case Users.delete_user(socket.assigns.current_user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:current_user, nil)
         |> put_flash(:info, "Account deleted successfully.")
         |> push_redirect(to: Routes.root_index_path(socket, :index))}

      {:error, error_msg} ->
        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  defp load_data(_params, socket) do
    socket
    |> assign(:changeset, Users.change_user(socket.assigns.current_user))
    |> assign(:user, socket.assigns.current_user)
  end
end
