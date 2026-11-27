defmodule Portal.Endpoint.Drainer do
  @moduledoc """
  Drains the channels of every socket when the node shuts down, 100 at a time every 100ms, so
  that devices do not all reconnect at once. It then waits until each channel has stopped.

  Supervise this process after the endpoints, so that it stops before they do. Phoenix's own
  drainer does not wait after its last batch: the endpoint can then stop a channel before the
  channel closes its socket, and the device gets `phx_error` on a socket that stays open.
  """

  use GenServer

  require Logger

  @batch_size 100
  @batch_interval 100
  @shutdown :timer.seconds(60)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: @shutdown}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, Keyword.fetch!(opts, :endpoints)}
  end

  @impl true
  def terminate(_reason, endpoints) do
    # Leave a second for the supervisor, which kills this process at @shutdown.
    deadline = System.monotonic_time(:millisecond) + @shutdown - 1_000
    channels = Enum.flat_map(endpoints, &channels/1)

    Logger.info("Draining #{length(channels)} channel(s)")

    channels
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, index} ->
      if index > 0 do
        Process.sleep(@batch_interval)
      end

      Enum.map(batch, &drain/1)
    end)
    |> MapSet.new()
    |> await(deadline)
  end

  # Endpoint and socket modules, not user input.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp channels(endpoint) do
    for {_path, handler, _opts} <- endpoint.__sockets__(),
        {_id, partition, _type, _modules} <- children(Module.concat(endpoint, handler)),
        {_id, channel, _type, _modules} <- children(partition),
        is_pid(channel),
        do: channel
  end

  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end

  defp drain(channel) do
    ref = Process.monitor(channel)
    send(channel, %Phoenix.Socket.Broadcast{event: "phx_drain"})
    ref
  end

  defp await(refs, deadline) do
    if MapSet.size(refs) > 0 do
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ref, :process, _pid, _reason} -> await(MapSet.delete(refs, ref), deadline)
      after
        timeout -> Logger.warning("#{MapSet.size(refs)} channel(s) did not stop in time")
      end
    end

    :ok
  end
end
