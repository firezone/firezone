defmodule API.Gateway.Views.Relay do
  def render_many(relays, salt, expires_at) do
    API.Client.Views.Relay.render_many(relays, salt, expires_at)
  end
end
