defmodule FzHttpWeb.OIDCLive.ConnectionsTableComponent do
  @moduledoc """
  OIDC Connections table
  """
  use FzHttpWeb, :live_component

  alias FzHttpWeb.Router.Helpers, as: Routes

  def handle_event("refresh", _payload, socket) do
    DynamicSupervisor.start_child(
      FzHttp.RefresherSupervisor,
      {FzHttp.OIDC.Refresher, {socket.assigns.user.id, 1000}}
    )

    {:noreply,
     socket
     |> put_flash(:info, "A refresh is underway, please check back in a minute.")
     |> push_patch(to: Routes.user_show_path(socket, :show, socket.assigns.user.id))}
  end
end
