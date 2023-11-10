defmodule API.Client.Views.Relay do
  alias Domain.Relays

  def render_many(relays, expires_at, conn_type) do
    Enum.flat_map(relays, &render(&1, expires_at, conn_type))
  end

  def render(%Relays.Relay{} = relay, expires_at, conn_type) do
    [
      maybe_render(relay, expires_at, relay.ipv4, conn_type),
      maybe_render(relay, expires_at, relay.ipv6, conn_type)
    ]
    |> List.flatten()
  end

  defp maybe_render(%Relays.Relay{}, _expires_at, nil, _conn_type), do: []

  defp maybe_render(%Relays.Relay{} = relay, expires_at, address, conn_type) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, expires_at)

    # type is either :turn or :stun
    [
      %{
        type: conn_type,
        uri: "#{Atom.to_string(conn_type)}:#{format_address(address)}:#{relay.port}",
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
