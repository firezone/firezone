defmodule Domain.Flows.Jobs.DeleteExpiredFlows do
  @moduledoc """
  Job to delete expired flows.
  """
  use Oban.Worker, queue: :default

  alias Domain.Flows

  @impl Oban.Worker
  def perform(_args) do
    dbg(Flows.delete_expired_flows())
    :ok
  end
end
