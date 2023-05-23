defmodule API.Client.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Clients}

  ## Channels

  channel "client:*", API.Client.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token} = attrs, socket, connect_info) do
    %{user_agent: user_agent, peer_data: %{address: remote_ip}} = connect_info

    with {:ok, subject} <- Auth.sign_in(token, user_agent, remote_ip),
         {:ok, client} <- Clients.upsert_client(attrs, subject) do
      socket =
        socket
        |> assign(:subject, subject)
        |> assign(:client, client)

      {:ok, socket}
    else
      {:error, :unauthorized} ->
        {:error, :invalid}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :invalid}
  end

  @impl true
  def id(socket), do: "client:#{socket.assigns.client.id}"
end
