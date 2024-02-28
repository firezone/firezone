defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, expires_at, stun_or_turn \\ :turn) do
    Enum.flat_map(relays, &render(&1, expires_at, stun_or_turn))
  end

  # STUN returns the reflective candidates to the peer and is used for hole-punching;
  # TURN is used to real actual traffic if hole-punching fails. It requires authentication.
  # WebRTC will automatically fail back to STUN if TURN fails,
  # so there is no need to send both of them along with each other.

  def render(%Relays.Relay{} = relay, _expires_at, :stun) do
    ipv4_addr = if relay.ipv4, do: "#{format_address(relay.ipv4)}:#{relay.port}"
    ipv6_addr = if relay.ipv6, do: "#{format_address(relay.ipv6)}:#{relay.port}"

    [
      %{
        id: relay.id,
        type: :stun,
        ipv4_addr: ipv4_addr,
        ipv6_addr: ipv6_addr
      }
    ]
  end

  def render(%Relays.Relay{} = relay, expires_at, :turn) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, expires_at)

    ipv4_addr = if relay.ipv4, do: "#{format_address(relay.ipv4)}:#{relay.port}"
    ipv6_addr = if relay.ipv6, do: "#{format_address(relay.ipv6)}:#{relay.port}"

    [
      %{
        id: relay.id,
        type: :turn,
        addr: ipv4_addr || ipv6_addr,
        ipv4_addr: ipv4_addr,
        ipv6_addr: ipv6_addr,
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
