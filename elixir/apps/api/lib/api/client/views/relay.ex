defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, expires_at, stun_or_turn) do
    Enum.flat_map(relays, &render(&1, expires_at, stun_or_turn))
  end

  def render(%Relays.Relay{} = relay, expires_at, stun_or_turn) do
    [
      maybe_render(relay, expires_at, relay.ipv4, stun_or_turn),
      maybe_render(relay, expires_at, relay.ipv6, stun_or_turn)
    ]
    |> List.flatten()
  end

  defp maybe_render(%Relays.Relay{}, _expires_at, nil, _stun_or_turn), do: []

  defp maybe_render(%Relays.Relay{} = relay, _expires_at, address, :stun) do
    [
      %{
        type: :stun,
        uri: "stun:#{format_address(address)}:#{relay.port}"
      }
    ]
  end

  defp maybe_render(%Relays.Relay{} = relay, expires_at, address, :turn) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, expires_at)

    [
      %{
        type: :turn,
        uri: "turn:#{format_address(address)}:#{relay.port}",
        username: username,
        password: password,
        expires_at: expires_at
      }
    ]
  end

  defp format_address(%Postgrex.INET{address: address} = inet) when tuple_size(address) == 4,
    do: inet

  defp format_address(%Postgrex.INET{address: address} = inet) when tuple_size(address) == 8,
    do: "[#{inet}]"
end
