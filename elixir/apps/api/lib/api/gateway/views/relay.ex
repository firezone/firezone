defmodule API.Gateway.Views.Relay do
  def render_many(relays, expires_at) do
    API.Client.Views.Relay.render_many(relays, expires_at)
  end
end
