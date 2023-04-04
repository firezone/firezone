defmodule Web.OIDCLive.ConnectionsTableComponent do
  @moduledoc """
  OIDC Connections table
  """
  use Web, :live_component
  alias Domain.Auth.OIDC

  def handle_event("refresh", _payload, socket) do
    DynamicSupervisor.start_child(
      Domain.RefresherSupervisor,
      {Domain.Auth.OIDC.Refresher, {socket.assigns.user.id, 1000}}
    )

    {:noreply,
     socket
     |> put_flash(:info, "A refresh is underway, please check back in a minute.")
     |> push_redirect(to: ~p"/users/#{socket.assigns.user}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    conn = OIDC.get_connection!(id)
    {:ok, _connection} = OIDC.delete_connection(conn)

    {:noreply,
     socket
     |> put_flash(:info, "The #{conn.provider} connection is deleted.")
     |> push_redirect(to: ~p"/users/#{socket.assigns.user}")}
  end

  defp delete_warning(conn) do
    "Deleting the connection will prevent their VPN session from being " <>
      "disabled for any OIDC errors from #{conn.provider} until the " <>
      "connection is re-established. Proceed?"
  end
end
