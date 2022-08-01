defmodule FzHttpWeb.SettingLive.Unprivileged.AccountFormComponent do
  @moduledoc """
  Handles the edit account form for unprivileged users.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Users

  def update(assigns, socket) do
    changeset = Users.change_user(assigns.current_user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Users.unprivileged_update_self(socket.assigns.current_user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password updated successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
