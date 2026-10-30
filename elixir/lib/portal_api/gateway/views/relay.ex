defmodule PortalAPI.Gateway.Views.Relay do
  def render_many(relays, salt, expires_at, account_id) do
    PortalAPI.Client.Views.Relay.render_many(relays, salt, expires_at, account_id)
  end
end
