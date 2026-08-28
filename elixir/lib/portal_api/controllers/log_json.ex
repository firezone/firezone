defmodule PortalAPI.LogJSON do
  use PortalAPI.JSON,
    variants: [
      [
        struct: Portal.ChangeLog,
        schema: PortalAPI.Schemas.Log.Change,
        computed: [:type],
        internal: [:account_id, :lsn, :seq, :vsn]
      ],
      [
        struct: Portal.SessionLog,
        schema: PortalAPI.Schemas.Log.Session,
        computed: [:type],
        internal: [:account_id, :seq]
      ],
      [
        struct: Portal.FlowLog,
        schema: PortalAPI.Schemas.Log.Flow,
        computed: [:type, :inner_src_ip, :inner_dst_ip, :outers],
        aliases: [timestamp: :inserted_at, inner_domain: :domain],
        internal: [:account_id, :seq, :start_seq]
      ],
      [
        struct: Portal.APIRequestLog,
        schema: PortalAPI.Schemas.Log.APIRequest,
        computed: [:type, :ip],
        aliases: [timestamp: :inserted_at],
        internal: [:account_id, :seq]
      ]
    ]

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

  defp data(%ChangeLog{} = log), do: render_fields(log, %{type: "change"})

  defp data(%SessionLog{} = log), do: render_fields(log, %{type: "session"})

  defp data(%FlowLog{} = log) do
    render_fields(log, %{
      type: "flow",
      inner_src_ip: log.inner_src_ip && "#{log.inner_src_ip}",
      inner_dst_ip: log.inner_dst_ip && "#{log.inner_dst_ip}",
      outers: flow_outers(log)
    })
  end

  defp data(%APIRequestLog{} = log) do
    render_fields(log, %{type: "api_request", ip: log.ip && "#{log.ip}"})
  end

  defp flow_outers(%FlowLog{flow_end: nil}), do: nil
  defp flow_outers(%FlowLog{outers: outers}), do: FlowLog.outers_to_maps(outers)
end
