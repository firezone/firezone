defmodule FzHttpWeb.OIDCLive.ConnectionsTableComponent do
  @moduledoc """
  OIDC Connections table
  """
  use FzHttpWeb, :live_component

  alias FzHttp.OIDC
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

  def handle_event("delete", %{"id" => id}, socket) do
    conn = OIDC.get_connection!(id)
    {:ok, _connection} = OIDC.delete_connection(conn)

    {:noreply,
     socket
     |> put_flash(:info, "The #{conn.provider} connection is deleted.")
     |> push_redirect(to: Routes.user_show_path(socket, :show, socket.assigns.user.id))}
  end

  defp delete_warning(conn) do
    "Deleting the connection will prevent their VPN session from being " <>
      "disabled for any OIDC errors from #{conn.provider} until the " <>
      "connection is re-established. Proceed?"
  end
end
