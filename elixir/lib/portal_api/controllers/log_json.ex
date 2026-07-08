defmodule PortalAPI.LogJSON do
  alias PortalAPI.Pagination
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
      subject: log.subject
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
      inner_domain: log.domain,
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
end
