defmodule Domain.Flows.Jobs.DeleteExpiredFlows do
  @moduledoc """
  Job to delete expired flows.
  """
  use Oban.Worker, queue: :default

  require Logger

  alias Domain.Flows

  @impl Oban.Worker
  def perform(_args) do
    {count, nil} = Flows.delete_expired_flows()

    Logger.info("Deleted #{count} expired flows")

    :ok
  end
end
