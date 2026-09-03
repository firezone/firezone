defmodule PortalAPI.LogJSON do
  alias PortalAPI.Schemas.Log

  PortalAPI.JSON.verify!(__MODULE__, Portal.ChangeLog, Log.Change,
    computed: [:type],
    internal: [:account_id, :lsn, :seq, :vsn]
  )

  PortalAPI.JSON.verify!(__MODULE__, Portal.SessionLog, Log.Session,
    computed: [:type],
    internal: [:account_id, :seq]
  )

  PortalAPI.JSON.verify!(__MODULE__, Portal.FlowLog, Log.Flow,
    computed: [:type, :timestamp, :inner_src_ip, :inner_dst_ip, :inner_domain, :outers],
    internal: [:account_id, :domain, :inserted_at, :seq, :start_seq]
  )

  PortalAPI.JSON.verify!(__MODULE__, Portal.APIRequestLog, Log.APIRequest,
    computed: [:type, :timestamp, :ip],
    internal: [:account_id, :inserted_at, :seq]
  )

  alias PortalAPI.JSON
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

  def flow_log(%FlowLog{} = log), do: data(log)

  defp data(%ChangeLog{} = log),
    do: JSON.render(log, Log.Change, %{type: "change"})

  defp data(%SessionLog{} = log),
    do: JSON.render(log, Log.Session, %{type: "session"})

  defp data(%FlowLog{} = log) do
    JSON.render(log, Log.Flow, %{
      type: "flow",
      timestamp: log.inserted_at,
      inner_src_ip: log.inner_src_ip && "#{log.inner_src_ip}",
      inner_dst_ip: log.inner_dst_ip && "#{log.inner_dst_ip}",
      inner_domain: log.domain,
      outers: flow_outers(log)
    })
  end

  defp data(%APIRequestLog{} = log) do
    JSON.render(log, Log.APIRequest, %{
      type: "api_request",
      timestamp: log.inserted_at,
      ip: log.ip && "#{log.ip}"
    })
  end

  defp flow_outers(%FlowLog{flow_end: nil}), do: nil
  defp flow_outers(%FlowLog{outers: outers}), do: FlowLog.outers_to_maps(outers)
end
