defmodule PortalWeb.LiveHooks.EnsureAuthenticated do
  use PortalWeb, :verified_routes

  import Phoenix.LiveView

  alias Portal.Authentication.Subject

  def on_mount(stage, _params, _session, %{assigns: %{subject: %Subject{}}} = socket)
      when stage in [:default, :oauth] do
    {:cont, socket}
  end

  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> put_flash(:error, "You must sign in to access that page.")
      |> redirect(to: ~p"/#{params["account_id_or_slug"]}/sign_in")

    {:halt, socket}
  end

  def on_mount(:oauth, params, _session, socket) do
    {:halt, redirect(socket, to: ~p"/#{params["account_id_or_slug"]}/sign_in?as=oauth")}
  end
end
