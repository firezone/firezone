defmodule API.Device.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Devices}
  require Logger

  ## Channels

  channel "device", API.Device.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token} = attrs, socket, connect_info) do
    %{
      user_agent: user_agent,
      x_headers: x_headers,
      peer_data: peer_data
    } = connect_info

    real_ip = API.Sockets.real_ip(x_headers, peer_data)

    with {:ok, subject} <- Auth.sign_in(token, user_agent, real_ip),
         {:ok, device} <- Devices.upsert_device(attrs, subject) do
      socket =
        socket
        |> assign(:subject, subject)
        |> assign(:device, device)

      {:ok, socket}
    else
      {:error, :unauthorized} ->
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.debug("Error connecting device websocket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: "device:#{socket.assigns.device.id}"
end
