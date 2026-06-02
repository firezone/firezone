defmodule PortalAPI.ChangeLogJSON do
  alias PortalAPI.Pagination
  alias Portal.ChangeLog

  def index(%{change_logs: change_logs, metadata: metadata}) do
    %{
      data: Enum.map(change_logs, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  def show(%{change_log: change_log}) do
    %{data: data(change_log)}
  end

  defp data(%ChangeLog{} = change_log) do
    %{
      event_id: change_log.event_id,
      timestamp: change_log.timestamp,
      object: change_log.object,
      operation: change_log.operation,
      before: change_log.before,
      after: change_log.after,
      subject: change_log.subject
    }
  end
end
