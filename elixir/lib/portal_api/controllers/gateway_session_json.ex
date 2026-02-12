defmodule PortalAPI.GatewaySessionJSON do
  alias PortalAPI.Pagination
  alias Portal.GatewaySession

  def index(%{gateway_sessions: gateway_sessions, metadata: metadata}) do
    %{
      data: Enum.map(gateway_sessions, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show(%{gateway_session: gateway_session}) do
    %{data: data(gateway_session)}
  end

  defp data(%GatewaySession{} = session) do
    %{
      id: session.id,
      gateway_id: session.gateway_id,
      gateway_token_id: session.gateway_token_id,
      last_seen_user_agent: session.user_agent,
      last_seen_remote_ip: session.remote_ip && "#{session.remote_ip}",
      last_seen_remote_ip_location_region: session.remote_ip_location_region,
      last_seen_remote_ip_location_city: session.remote_ip_location_city,
      last_seen_remote_ip_location_lat: session.remote_ip_location_lat,
      last_seen_remote_ip_location_lon: session.remote_ip_location_lon,
      last_seen_version: session.version,
      last_seen_at: session.inserted_at,
      created_at: session.inserted_at
    }
  end
end
