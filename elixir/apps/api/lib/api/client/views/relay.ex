defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, expires_at) do
    Enum.flat_map(relays, &render(&1, expires_at))
  end

  def render(%Relays.Relay{} = relay, expires_at) do
    [
      maybe_render(relay, expires_at, relay.ipv4),
      maybe_render(relay, expires_at, relay.ipv6)
    ]
    |> List.flatten()
  end

  defp maybe_render(%Relays.Relay{}, _expires_at, nil), do: []

  defp maybe_render(%Relays.Relay{} = relay, expires_at, address) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, expires_at)

    [
      # WebRTC automatically falls back to STUN if TURN fails,
      # so no need to send it explicitly
      # %{
      #   type: :stun,
      #   uri: "stun:#{format_address(address)}:#{relay.port}"
      # },
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
