defmodule PortalWeb.LiveHooks.EnsureAuthenticated do
  use Web, :verified_routes

  import Phoenix.LiveView

  alias Portal.Auth.Subject

  def on_mount(:default, _params, _session, %{assigns: %{subject: %Subject{}}} = socket) do
    {:cont, socket}
  end

  def on_mount(:default, params, _session, socket) do
    redirect_to = ~p"/#{params["account_id_or_slug"]}"

    socket =
      socket
      |> put_flash(:error, "You must sign in to access that page.")
      |> redirect(to: redirect_to)

    {:halt, socket}
  end
end
