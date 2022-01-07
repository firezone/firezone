defmodule FzHttpWeb.SettingLive.AccountFormComponent do
  @moduledoc """
  Handles the edit account form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Users

  def update(assigns, socket) do
    changeset = Users.change_user(assigns.user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.user

    case Users.update_user(user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
