defmodule API.Gateway.Views.Relay do
  def render_many(relays, expires_at, conn_type) do
    Enum.flat_map(relays, &API.Client.Views.Relay.render(&1, expires_at, conn_type))
  end
end
