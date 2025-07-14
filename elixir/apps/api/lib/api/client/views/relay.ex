defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, salt, expires_at) do
    relays
    |> Enum.map(fn relay ->
      [
        render_addr(relay, salt, expires_at, relay.ipv4),
        render_addr(relay, salt, expires_at, relay.ipv6)
      ]
    end)
    |> List.flatten()
  end

  defp render_addr(_relay, _salt, _expires_at, nil), do: []

  defp render_addr(%Relays.Relay{} = relay, salt, expires_at, address) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, salt, expires_at)

    %{
      id: relay.id,
      type: :turn,
      addr: "#{format_address(address)}:#{relay.port}",
      username: username,
      password: password,
      expires_at: expires_at
    }
  end

  defp format_address(%Postgrex.INET{address: address} = inet) when tuple_size(address) == 4,
    do: inet

  defp format_address(%Postgrex.INET{address: address} = inet) when tuple_size(address) == 8,
    do: "[#{inet}]"
end
