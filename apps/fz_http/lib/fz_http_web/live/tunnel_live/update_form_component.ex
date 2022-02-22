defmodule FzHttpWeb.TunnelLive.UpdateFormComponent do
  @moduledoc """
  Handles tunnel form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Sites, Tunnels}

  def update(assigns, socket) do
    tunnel = assigns.tunnel
    changeset = Tunnels.change_tunnel(tunnel)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(Tunnels.defaults(changeset))
     |> assign(Sites.wireguard_defaults())
     |> assign(:changeset, changeset)}
  end

  def handle_event("change", %{"tunnel" => tunnel_params}, socket) do
    changeset = Tunnels.change_tunnel(socket.assigns.tunnel, tunnel_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(Tunnels.defaults(changeset))}
  end

  def handle_event("save", %{"tunnel" => tunnel_params}, socket) do
    tunnel = socket.assigns.tunnel

    case Tunnels.update_tunnel(tunnel, tunnel_params) do
      {:ok, tunnel} ->
        @events_module.update_tunnel(tunnel)

        {:noreply,
         socket
         |> put_flash(:info, "Tunnel updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
