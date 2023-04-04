defmodule API.Client.Socket do
  use Phoenix.Socket

  ## Channels

  channel "client:*", API.Client.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token, "id" => external_id}, socket, connect_info) do
    %{user_agent: user_agent, peer_data: peer_data} = connect_info

    with {:ok, subject} <- Auth.fetch_subject_by_token(token),
         {:ok, client} <- Clients.upsert_client(external_id, user_agent, peer_data, subject) do
      {:ok, socket}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :invalid}
  end

  @impl true
  def id(socket), do: "client:#{socket.assigns.client.id}"
end
