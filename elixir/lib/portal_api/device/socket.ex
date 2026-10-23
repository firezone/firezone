defmodule PortalAPI.Device.Socket do
  @moduledoc """
  The `/device/v1` socket: one protocol for every device.

  A device connects with whatever credential it has. A user's or service
  account's client token, or a device certificate, makes it the device that
  token or certificate names, as on the client socket. A token minted for a
  site or a gateway makes it that gateway, as on the gateway socket. Either
  way the channel is the same, and the device gets both halves of the
  protocol: the resources it may reach, and what it serves.

  Only the unified binary speaks this protocol, so the socket refuses a
  connect that does not announce itself as `firezone/` or that leaves out
  its protocol range: a device that cannot say which protocol minors it
  speaks cannot be matched with a peer.
  """
  use Phoenix.Socket

  alias Portal.Authentication
  alias Portal.{ComponentVersions, Version}

  require Logger

  channel "device", PortalAPI.Device.V1.Channel

  @impl true
  def connect(attrs, socket, connect_info) do
    with :ok <- gate(attrs, connect_info),
         :ok <- rate_limit(attrs, connect_info) do
      case PortalAPI.Client.Socket.connect(attrs, socket, connect_info, rate_limit: false) do
        {:ok, socket} -> {:ok, as_device(socket, :client)}
        {:error, :invalid_token} -> connect_as_gateway(attrs, socket, connect_info)
        error -> error
      end
    end
  end

  # A token the client socket does not know is signed for the gateway socket.
  defp connect_as_gateway(attrs, socket, connect_info) do
    opts = [registration: :last_wins, rate_limit: false]

    case PortalAPI.Gateway.Socket.connect(attrs, socket, connect_info, opts) do
      {:ok, socket} -> {:ok, as_device(socket, :gateway)}
      error -> error
    end
  end

  # Counted once here, whichever credential the connect turns out to carry.
  defp rate_limit(attrs, connect_info) do
    case PortalAPI.Sockets.extract_token(attrs, connect_info) do
      {:ok, token} -> PortalAPI.Sockets.RateLimit.check(connect_info, token: token)
      {:error, :missing_token} -> PortalAPI.Sockets.RateLimit.check(connect_info, token: "x509")
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.subject.credential.id)

  # The feature gate: the unified binary with an explicit protocol range.
  defp gate(attrs, connect_info) do
    user_agent = Map.get(connect_info, :user_agent) || ""

    cond do
      not unified_binary?(user_agent) ->
        Logger.info("Refusing device socket connect: not the unified binary", user_agent: user_agent)
        {:error, :unsupported_client}

      is_nil(Version.proto_range(attrs, :client, nil)) ->
        Logger.info("Refusing device socket connect: no protocol range announced")
        {:error, :protocol_range_required}

      true ->
        :ok
    end
  end

  defp unified_binary?(user_agent) do
    match?({:ok, _}, Version.fetch_version(user_agent)) and
      ComponentVersions.get_component_type_from_user_agent(user_agent) == :firezone
  end

  # Whatever socket the credential led to, the channel reads the device under
  # one name. A gateway's row has no actor of its own; the subject's actor,
  # the account's Infrastructure actor, is what its outbound view is built
  # for, so it is set here where only this connection sees it.
  defp as_device(socket, :client) do
    assign(socket, :device, socket.assigns.client)
  end

  defp as_device(socket, :gateway) do
    gateway = socket.assigns.gateway
    device = %{gateway | actor_id: gateway.actor_id || socket.assigns.subject.actor.id}

    socket
    |> assign(:device, device)
    |> assign(:subject, Authentication.Subject.with_device(socket.assigns.subject, device))
  end
end
