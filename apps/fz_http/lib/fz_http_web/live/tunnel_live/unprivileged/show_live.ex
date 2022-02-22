defmodule FzHttpWeb.TunnelLive.Unprivileged.Show do
  @moduledoc """
  Shows a tunnel for an unprivileged user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Tunnels, Users}

  @impl Phoenix.LiveView
  def mount(%{"id" => tunnel_id} = _params, _session, socket) do
    tunnel = Tunnels.get_tunnel!(tunnel_id)

    if authorized?(tunnel, socket) do
      {:ok,
       socket
       |> assign(assigns(tunnel))}
    else
      {:ok, not_authorized(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("delete_tunnel", _params, socket) do
    tunnel = socket.assigns.tunnel

    case delete_tunnel(tunnel, socket) do
      {:ok, _deleted_tunnel} ->
        {:ok, _deleted_pubkey} = @events_module.delete_tunnel(tunnel.public_key)

        {:noreply,
         socket
         |> redirect(to: Routes.tunnel_unprivileged_index_path(socket, :index))}

      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

        # Not likely to ever happen
        # {:error, msg} ->
        #   {:noreply,
        #   socket
        #   |> put_flash(:error, "Error deleting tunnel: #{msg}")}
    end
  end

  def delete_tunnel(tunnel, socket) do
    if socket.assigns.current_user.id == tunnel.user_id do
      Tunnels.delete_tunnel(tunnel)
    else
      {:not_authorized}
    end
  end

  defp assigns(tunnel) do
    [
      tunnel: tunnel,
      user: Users.get_user!(tunnel.user_id),
      page_title: tunnel.name,
      allowed_ips: Tunnels.allowed_ips(tunnel),
      port: Application.fetch_env!(:fz_vpn, :wireguard_port),
      dns: Tunnels.dns(tunnel),
      endpoint: Tunnels.endpoint(tunnel),
      mtu: Tunnels.mtu(tunnel),
      persistent_keepalive: Tunnels.persistent_keepalive(tunnel),
      config: Tunnels.as_config(tunnel)
    ]
  end

  defp authorized?(tunnel, socket) do
    "#{tunnel.user_id}" == "#{socket.assigns.current_user.id}" || has_role?(socket, :admin)
  end
end
