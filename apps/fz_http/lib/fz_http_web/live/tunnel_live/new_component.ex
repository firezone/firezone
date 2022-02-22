defmodule FzHttpWeb.TunnelLive.NewComponent do
  @moduledoc """
  Manages new tunnel modal.
  """
  use FzHttpWeb, :live_component

  alias FzCommon.NameGenerator
  alias FzHttp.Tunnels
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Tunnels.new_tunnel())}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_tunnel", params, socket) do
    case create_tunnel(params, socket) do
      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Error creating tunnel: #{ErrorHelpers.aggregated_errors(changeset)}"
         )}

      {:ok, tunnel} ->
        @events_module.update_tunnel(tunnel)
        {:reply, %{public_key: tunnel.public_key, config: Tunnels.as_config(tunnel)}, socket}
    end
  end

  defp create_tunnel(%{"user_id" => user_id, "public_key" => public_key} = _params, socket) do
    # Whitelist only name, user_id, public_key
    params = %{
      "user_id" => user_id,
      "public_key" => public_key,
      "name" => NameGenerator.generate()
    }

    if authorized_to_create?(user_id, socket) do
      Tunnels.create_tunnel(params)
    else
      {:not_authorized}
    end
  end

  defp authorized_to_create?(user_id, socket) do
    "#{socket.assigns.target_user_id}" == "#{user_id}"
  end
end
