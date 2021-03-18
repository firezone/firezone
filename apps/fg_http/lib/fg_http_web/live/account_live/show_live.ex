defmodule FgHttpWeb.AccountLive.Show do
  @moduledoc """
  Handles Account-related things.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.Users

  def mount(params, sess, sock), do: mount_defaults(params, sess, assign_defaults(sock, params))

  def mount_defaults(_params, %{"current_user" => current_user}, socket) do
    {:ok,
     socket
     |> assign(:user, current_user)}
  end

  def handle_event("update_user", %{"user" => user_params}, socket) do
    user = Users.get_user!(socket.assigns.current_user.id)

    case Users.update_user(user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully.")
         |> redirect(to: Routes.account_path(socket, :show))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error updating account.")
         |> assign(:changeset, changeset)}
    end
  end
end
