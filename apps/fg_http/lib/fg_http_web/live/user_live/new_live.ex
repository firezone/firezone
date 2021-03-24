defmodule FgHttpWeb.UserLive.New do
  @moduledoc """
  LiveView for user sign up.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.Users

  def mount(_params, _session, socket) do
    changeset = Users.new_user()
    {:ok, assign(socket, :changeset, changeset)}
  end

  def handle_event("create_user", %{"user" => user_params}, socket) do
    sign_in_params = Users.sign_in_params()
    params = Map.merge(user_params, sign_in_params)

    case Users.create_user(params) do
      {:ok, _user} ->
        {:noreply,
         redirect(socket,
           to: Routes.session_path(socket, :create, sign_in_params["sign_in_token"])
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error creating user.")
         |> assign(:changeset, changeset)}
    end
  end
end
