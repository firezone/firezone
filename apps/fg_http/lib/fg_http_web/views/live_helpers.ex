defmodule FgHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  """
  import Phoenix.LiveView
  alias FgHttp.Users
  alias FgHttpWeb.Router.Helpers, as: Routes

  def assign_defaults(socket, %{"user_id" => user_id}) do
    socket = assign_new(socket, :current_user, fn -> Users.get_user!(user_id) end)

    if socket.assigns.current_user.confirmed_at do
      socket
    else
      socket
      |> put_flash(:error, "You must be signed in to access that page.")
      |> redirect(to: Routes.session_path(socket, :new))
    end
  end
end
