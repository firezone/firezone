defmodule PortalAPI.Channel.Authorizations do
  @moduledoc """
  Policy authorizations a device's channel holds, shared by Clients and Gateways.
  """
  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.Cache

  @doc """
  Drops a policy authorization from the channel's cache: on a CDC delete, a failed insert, or a
  durability timeout. The device is told to end the flow only if the authorization has not
  expired yet, because the device already ends expired ones.
  """
  @spec revoke(Phoenix.Socket.t(), Portal.PolicyAuthorization.t()) :: {:noreply, Phoenix.Socket.t()}
  def revoke(socket, %Portal.PolicyAuthorization{
        id: id,
        initiating_device_id: initiating_device_id,
        resource_id: resource_id
      }) do
    case Cache.Authorizations.delete(socket.assigns.authorizations_cache, id, initiating_device_id, resource_id) do
      {:ok, expires_at_unix, authorizations_cache} ->
        if expires_at_unix > DateTime.to_unix(DateTime.utc_now(), :second) do
          push(socket, "reject_access", %{client_id: initiating_device_id, resource_id: resource_id})
        end

        {:noreply, assign(socket, :authorizations_cache, authorizations_cache)}

      :error ->
        {:noreply, socket}
    end
  end
end
