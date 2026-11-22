defmodule PortalAPI.Device.Socket do
  @moduledoc """
  The `/device/v1` socket, for the binary that both reaches and serves resources.

  A device connects with the same credentials as on the client socket, or with a Gateway
  token. A Gateway token connects the same device row as on the gateway socket, which then
  only serves its sites. A device also states the range of protocol minors it speaks, as
  `proto_min` and `proto_max`, and with `frostlink` whether it connects to its peers without
  ICE where the account allows it.
  """
  use Phoenix.Socket

  channel "device", PortalAPI.Device.V1.Channel

  @impl true
  def connect(attrs, socket, connect_info) do
    with {:ok, socket} <- connect_device(attrs, socket, connect_info),
         {:ok, proto_range} <- proto_range(attrs) do
      {:ok,
       assign(socket,
         proto_range: proto_range,
         iceless_capable: Map.get(attrs, "frostlink") == "true"
       )}
    end
  end

  # The token id is the credential id for both kinds, so revoking a token disconnects it.
  @impl true
  defdelegate id(socket), to: PortalAPI.Client.Socket

  # A Gateway connect can create or move the gateway, so a bad range is refused first.
  defp connect_device(attrs, socket, connect_info) do
    if gateway_token?(attrs, connect_info) do
      with {:ok, _range} <- proto_range(attrs), do: connect_gateway(attrs, socket, connect_info)
    else
      PortalAPI.Client.Socket.connect(attrs, socket, connect_info)
    end
  end

  defp gateway_token?(attrs, connect_info) do
    case PortalAPI.Sockets.extract_token(attrs, connect_info) do
      {:ok, encoded_token} ->
        unless Application.get_env(:portal, :sql_sandbox) do
          Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
        end

        Portal.Authentication.gateway_token?(encoded_token)

      {:error, _reason} ->
        false
    end
  end

  defp connect_gateway(attrs, socket, connect_info) do
    with {:ok, assigns} <- PortalAPI.Gateway.Connection.connect(attrs, connect_info) do
      {gateway, assigns} = Map.pop!(assigns, :gateway)

      assigns =
        assigns
        |> Map.delete(:site)
        |> Map.put(:client, gateway)

      {:ok, assign(socket, assigns)}
    end
  end

  defp proto_range(attrs) do
    case Portal.Version.declared_proto_range(attrs) do
      nil -> {:error, :invalid_proto_range}
      range -> {:ok, range}
    end
  end
end
