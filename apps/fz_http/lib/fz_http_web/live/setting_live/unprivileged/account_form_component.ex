defmodule FzHttpWeb.SettingLive.Unprivileged.AccountFormComponent do
  @moduledoc """
  Handles the edit account form for unprivileged users.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Users

  @allowed_params [
    "password",
    "password_confirmation"
  ]

  def update(assigns, socket) do
    changeset = Users.change_user(assigns.current_user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    allowed_params = Map.take(user_params, @allowed_params)

    case Users.update_user(socket.assigns.current_user, allowed_params) do
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
