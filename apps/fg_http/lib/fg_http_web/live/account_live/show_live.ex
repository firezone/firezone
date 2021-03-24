defmodule FgHttpWeb.AccountLive.Show do
  @moduledoc """
  Handles Account-related things.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.Users

  def mount(params, session, socket) do
    {:ok, assign_defaults(params, session, socket, &load_data/2)}
  end

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

  defp load_data(_params, socket) do
    assign(socket, :user, socket.assigns.current_user)
  end
end
