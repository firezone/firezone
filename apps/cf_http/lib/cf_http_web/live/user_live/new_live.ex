defmodule CfHttpWeb.UserLive.New do
  @moduledoc """
  LiveView for user sign up.
  """
  use CfHttpWeb, :live_view

  alias CfHttp.Users

  def mount(_params, _session, socket) do
    changeset = Users.new_user()
    {:ok, assign(socket, :changeset, changeset)}
  end

  def handle_event("create_user", %{"user" => user_params}, socket) do
    case Users.create_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> redirect(to: Routes.session_path(socket, :create, user.sign_in_token))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error creating user.")
         |> assign(:changeset, changeset)}
    end
  end
end
