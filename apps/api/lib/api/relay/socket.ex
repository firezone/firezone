defmodule API.Relay.Socket do
  use Phoenix.Socket
  alias Domain.Relays

  ## Channels

  channel "relay:*", API.Relay.Channel

  ## Authentication

  def encode_token!(%Relays.Token{value: value} = token) when not is_nil(value) do
    body = {token.id, token.value}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt, body)
  end

  @impl true
  def connect(%{"token" => encrypted_secret} = attrs, socket, connect_info) do
    %{user_agent: user_agent, peer_data: %{address: remote_ip}} = connect_info

    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    max_age = Keyword.fetch!(config, :max_age)

    attrs =
      attrs
      |> Map.take(~w[ipv4 ipv6])
      |> Map.put("last_seen_user_agent", user_agent)
      |> Map.put("last_seen_remote_ip", remote_ip)

    with {:ok, {id, secret}} <-
           Plug.Crypto.verify(key_base, salt, encrypted_secret, max_age: max_age),
         {:ok, token} <- Relays.use_token_by_id_and_secret(id, secret),
         {:ok, relay} <- Relays.upsert_relay(token, attrs) do
      socket =
        socket
        |> assign(:relay, relay)

      {:ok, socket}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :invalid}
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:api, __MODULE__)
  end

  @impl true
  def id(socket), do: "relay:#{socket.assigns.relay.id}"
end
