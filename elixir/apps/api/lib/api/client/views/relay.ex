defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, salt, expires_at, stun_or_turn \\ :turn) do
    Enum.flat_map(relays, &render(&1, salt, expires_at, stun_or_turn))
  end

  def render(%Relays.Relay{} = relay, salt, expires_at, stun_or_turn) do
    [
      maybe_render(relay, salt, expires_at, relay.ipv4, stun_or_turn),
      maybe_render(relay, salt, expires_at, relay.ipv6, stun_or_turn)
    ]
    |> List.flatten()
  end

  defp maybe_render(%Relays.Relay{}, _salt, _expires_at, nil, _stun_or_turn), do: []

  # STUN returns the reflective candidates to the peer and is used for hole-punching;
  # TURN is used to real actual traffic if hole-punching fails. It requires authentication.

  defp maybe_render(%Relays.Relay{} = relay, _salt, _expires_at, address, :stun) do
    [
      %{
        id: relay.id,
        type: :stun,
        addr: "#{format_address(address)}:#{relay.port}"
      }
    ]
  end

  defp maybe_render(%Relays.Relay{} = relay, salt, expires_at, address, :turn) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, salt, expires_at)

    [
      %{
        id: relay.id,
        type: :turn,
        addr: "#{format_address(address)}:#{relay.port}",
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
