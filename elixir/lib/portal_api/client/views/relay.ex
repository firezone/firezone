defmodule PortalAPI.Client.Views.Relay do
  alias Portal.Relay

  def render_many(relays, salt, expires_at, account_id) do
    relays
    |> Enum.map(fn relay ->
      [
        render_addr(relay, salt, expires_at, account_id, relay.ipv4),
        render_addr(relay, salt, expires_at, account_id, relay.ipv6)
      ]
    end)
    |> List.flatten()
  end

  defp render_addr(_relay, _salt, _expires_at, _account_id, nil), do: []

  defp render_addr(%Relay{} = relay, salt, expires_at, account_id, address) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = generate_username_and_password(relay, salt, expires_at, account_id)

    %{
      id: relay.id,
      type: :turn,
      addr: "#{format_address(address)}:#{relay.port}",
      username: username,
      password: password,
      expires_at: expires_at
    }
  end

  # IPv4 string
  defp format_address(ip) when is_binary(ip) do
    if String.contains?(ip, ":"), do: "[#{ip}]", else: ip
  end

  defp generate_username_and_password(
         %Relay{stamp_secret: stamp_secret, turn_account_validation: true},
         public_key,
         expires_at,
         account_id
       )
       when is_binary(stamp_secret) do
    salt = generate_hash(public_key)
    account = hash_account_id(account_id)
    expires_at = DateTime.to_unix(expires_at, :second)
    username = "#{expires_at}:#{account}:#{salt}"
    password = generate_hash("#{username}:#{stamp_secret}")

    %{username: username, password: password, expires_at: expires_at}
  end

  defp generate_username_and_password(%Relay{stamp_secret: stamp_secret}, public_key, expires_at, _account_id)
       when is_binary(stamp_secret) do
    salt = generate_hash(public_key)
    expires_at = DateTime.to_unix(expires_at, :second)
    password = generate_hash("#{expires_at}:#{stamp_secret}:#{salt}")

    %{username: "#{expires_at}:#{salt}", password: password, expires_at: expires_at}
  end

  def hash_account_id(account_id) when is_binary(account_id) do
    generate_hash(account_id)
  end

  defp generate_hash(string) do
    :crypto.hash(:sha256, string)
    |> Base.encode64(padding: false)
  end
end
