defmodule PortalAPI.ClientSessionJSON do
  alias PortalAPI.Pagination
  alias Portal.ClientSession

  def index(%{client_sessions: client_sessions, metadata: metadata}) do
    %{
      data: Enum.map(client_sessions, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show(%{client_session: client_session}) do
    %{data: data(client_session)}
  end

  defp data(%ClientSession{} = session) do
    %{
      id: session.id,
      client_id: session.client_id,
      client_token_id: session.client_token_id,
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
