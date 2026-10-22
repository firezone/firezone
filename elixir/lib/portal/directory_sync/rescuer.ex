defmodule Portal.DirectorySync.Rescuer do
  @moduledoc """
  Re-queues the sync jobs this node leaves executing when it shuts down.

  Oban stops its queues with a short grace period and then kills the jobs
  still running, which leaves their rows in `executing`. Started before Oban,
  this process stops after it, so by the time `terminate/2` runs the jobs are
  gone and their rows can be handed to another node right away instead of
  blocking their directories until the rows age out.

  It only acts on a shutdown that has already stopped Oban. Any other stop,
  such as a crash while Oban keeps running, leaves the rows alone: those jobs
  are still writing.
  """
  use GenServer

  alias Portal.DirectorySync
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       node: Keyword.get_lazy(opts, :node, &Oban.Config.node_name/0),
       oban: Keyword.get(opts, :oban, Oban)
     }}
  end

  @impl true
  def terminate(:shutdown, %{node: node, oban: oban}) do
    if is_nil(Oban.Registry.whereis(oban)) do
      DirectorySync.rescue_orphans(node)
    else
      Logger.warning("Directory sync rescuer stopped while Oban still runs, leaving jobs alone",
        node: node
      )
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok
end
