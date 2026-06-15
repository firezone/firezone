defmodule PortalAPI.LogJSON do
  alias PortalAPI.Pagination
  alias Portal.APIRequestLog
  alias Portal.ChangeLog
  alias Portal.FlowLog
  alias Portal.SessionLog

  def index(%{logs: logs, metadata: metadata}) do
    %{
      data: Enum.map(logs, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show(%{log: log}) do
    %{data: data(log)}
  end

  defp data(%ChangeLog{} = log) do
    %{
      type: "change",
      event_id: log.event_id,
      timestamp: log.timestamp,
      object: log.object,
      operation: log.operation,
      before: log.before,
      after: log.after,
      subject: log.subject
    }
  end

  defp data(%SessionLog{} = log) do
    %{
      type: "session",
      event_id: log.event_id,
      timestamp: log.timestamp,
      context: log.context,
      actor_id: log.actor_id,
      actor_email: log.actor_email,
      device_id: log.device_id,
      token_id: log.token_id,
      auth_provider_id: log.auth_provider_id,
      user_agent: log.user_agent,
      remote_ip: log.remote_ip && "#{log.remote_ip}",
      remote_ip_location_region: log.remote_ip_location_region,
      remote_ip_location_city: log.remote_ip_location_city,
      remote_ip_location_lat: log.remote_ip_location_lat,
      remote_ip_location_lon: log.remote_ip_location_lon
    }
  end

  defp data(%FlowLog{} = log) do
    %{
      type: "flow",
      event_id: log.event_id,
      timestamp: log.inserted_at,
      device_id: log.device_id,
      role: log.role,
      protocol: log.protocol,
      flow_start: log.flow_start,
      flow_end: log.flow_end,
      last_packet: log.last_packet,
      auth_provider_id: log.auth_provider_id,
      actor_id: log.actor_id,
      actor_name: log.actor_name,
      actor_email: log.actor_email,
      resource_id: log.resource_id,
      resource_name: log.resource_name,
      resource_address: log.resource_address,
      inner_src_ip: log.inner_src_ip && "#{log.inner_src_ip}",
      inner_dst_ip: log.inner_dst_ip && "#{log.inner_dst_ip}",
      inner_src_port: log.inner_src_port,
      inner_dst_port: log.inner_dst_port,
      inner_domain: log.inner_domain,
      outer_src_ip: log.outer_src_ip && "#{log.outer_src_ip}",
      outer_dst_ip: log.outer_dst_ip && "#{log.outer_dst_ip}",
      outer_src_port: log.outer_src_port,
      outer_dst_port: log.outer_dst_port,
      rx_packets: log.rx_packets,
      tx_packets: log.tx_packets,
      rx_bytes: log.rx_bytes,
      tx_bytes: log.tx_bytes
    }
  end

  defp data(%APIRequestLog{} = log) do
    %{
      type: "api_request",
      event_id: log.event_id,
      timestamp: log.inserted_at,
      actor_id: log.actor_id,
      api_token_id: log.api_token_id,
      method: log.method,
      path: log.path,
      content_length: log.content_length,
      request_id: log.request_id,
      user_agent: log.user_agent,
      remote_ip: log.remote_ip && "#{log.remote_ip}",
      remote_ip_location_region: log.remote_ip_location_region,
      remote_ip_location_city: log.remote_ip_location_city,
      remote_ip_location_lat: log.remote_ip_location_lat,
      remote_ip_location_lon: log.remote_ip_location_lon
    }
  end
end
