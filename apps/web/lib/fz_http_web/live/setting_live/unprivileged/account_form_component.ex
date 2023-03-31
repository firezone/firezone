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

  def handle_event("save", %{"user" => attrs}, socket) do
    case Users.update_self(attrs, socket.assigns.subject) do
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
