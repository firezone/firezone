defmodule FzHttpWeb.TunnelLive.Admin.Show do
  @moduledoc """
  Shows a tunnel for an admin user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Tunnels, Users}

  @impl Phoenix.LiveView
  def mount(%{"id" => tunnel_id} = _params, _session, socket) do
    tunnel = Tunnels.get_tunnel!(tunnel_id)

    if tunnel.user_id == socket.assigns.current_user.id || has_role?(socket, :admin) do
      {:ok,
       socket
       |> assign(assigns(tunnel))}
    else
      {:ok, not_authorized(socket)}
    end
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_tunnel", _params, socket) do
    tunnel = socket.assigns.tunnel

    case Tunnels.delete_tunnel(tunnel) do
      {:ok, _deleted_tunnel} ->
        {:ok, _deleted_pubkey} = @events_module.delete_tunnel(tunnel.public_key)

        {:noreply,
         socket
         |> redirect(to: Routes.tunnel_admin_index_path(socket, :index))}

        # Not likely to ever happen
        # {:error, msg} ->
        #   {:noreply,
        #   socket
        #   |> put_flash(:error, "Error deleting tunnel: #{msg}")}
    end
  end

  defp assigns(tunnel) do
    [
      tunnel: tunnel,
      user: Users.get_user!(tunnel.user_id),
      page_title: tunnel.name,
      allowed_ips: Tunnels.allowed_ips(tunnel),
      dns: Tunnels.dns(tunnel),
      endpoint: Tunnels.endpoint(tunnel),
      port: Application.fetch_env!(:fz_vpn, :wireguard_port),
      mtu: Tunnels.mtu(tunnel),
      persistent_keepalive: Tunnels.persistent_keepalive(tunnel),
      config: Tunnels.as_config(tunnel)
    ]
  end
end
