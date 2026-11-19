defmodule PortalAPI.Channel.Authorizations do
  @moduledoc """
  Policy authorizations a device's channel holds, shared by Clients and Gateways.
  """
  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Account, Cache, Device, Telemetry}
  alias PortalAPI.Channel.Durability

  @doc """
  Accepts an authorization on the receiver's channel: records the grant, caches the
  authorization, and arms its durability timer. Returns whether the flow skips ICE, which needs
  the account feature and both devices to be capable.
  """
  @spec accept(Phoenix.Socket.t(), Device.t(), Account.t(), map()) :: {boolean(), Phoenix.Socket.t()}
  def accept(socket, %Device{} = receiver, %Account{} = account, %{initiator: %{id: initiator_id}} = request) do
    iceless_feature_enabled = Account.iceless_enabled?(account)
    initiator_capable = request.initiator_iceless_capable == true
    receiver_capable = socket.assigns.iceless_capable == true

    Telemetry.authorization_granted(receiver.type,
      iceless_feature_enabled: iceless_feature_enabled,
      initiator_iceless_capable: initiator_capable,
      receiver_iceless_capable: receiver_capable
    )

    socket =
      socket
      |> assign(:authorizations_cache, put(socket.assigns.authorizations_cache, initiator_id, request))
      |> Durability.arm_authorization(request[:policy_authorization])

    {iceless_feature_enabled and initiator_capable and receiver_capable, socket}
  end

  @doc """
  Tells the initiator's channel that the receiver accepted, with what the initiator needs to
  connect to it.
  """
  @spec reply(pid(), reference(), Device.t(), map()) :: :ok
  def reply(initiator_pid, ref, %Device{} = receiver, attrs) do
    reply =
      receiver
      |> Map.take([:name, :slug, :public_key, :ipv4, :ipv6])
      |> Map.put(:receiver_id, receiver.id)
      |> Map.merge(attrs)

    send(initiator_pid, {:authorized, ref, reply})
    :ok
  end

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

  defp put(cache, initiator_id, %{
         resource: %{id: resource_id},
         policy_authorization_id: policy_authorization_id,
         expires_at: %DateTime{} = expires_at
       })
       when not is_nil(initiator_id) and not is_nil(policy_authorization_id) do
    Cache.Authorizations.put(cache, policy_authorization_id, initiator_id, resource_id, expires_at)
  end

  defp put(cache, _initiator_id, _request), do: cache
end
