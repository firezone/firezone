defmodule API.Gateway.Views.Relay do
  alias Domain.Relays

  def render_many(relays, expires_at) do
    Enum.flat_map(relays, &render(&1, expires_at))
  end

  def render(%Relays.Relay{} = relay, expires_at) do
    [
      maybe_render(relay, expires_at, relay.ipv4),
      maybe_render(relay, expires_at, relay.ipv6)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_render(%Relays.Relay{}, _expires_at, nil), do: nil

  defp maybe_render(%Relays.Relay{} = relay, expires_at, address) do
    %{
      username: username,
      password: password,
      expires_at: expires_at
    } = Relays.generate_username_and_password(relay, expires_at)

    %{
      uri: "stun:#{address}:#{relay.port}",
      username: username,
      password: password,
      expires_at: expires_at
    }
  end
end
