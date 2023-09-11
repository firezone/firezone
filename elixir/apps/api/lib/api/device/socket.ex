defmodule API.Client.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Clients}
  require Logger

  ## Channels

  channel "client", API.Client.Channel

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
         {:ok, client} <- Clients.upsert_client(attrs, subject) do
      socket =
        socket
        |> assign(:subject, subject)
        |> assign(:client, client)

      {:ok, socket}
    else
      {:error, :unauthorized} ->
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.debug("Error connecting client websocket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: "client:#{socket.assigns.client.id}"
end
