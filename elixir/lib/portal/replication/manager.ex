defmodule Portal.Replication.Manager do
  @moduledoc """
    Manages the Postgrex.ReplicationConnection to ensure that we always have one running to prevent
    unbounded growth of the WAL log and ensure we are processing events.
  """
  use GenServer
  require Logger

  # These should be enough to gracefully handle transient network issues and DB restarts,
  # but not too long to avoid consuming WAL data. When this limit is hit, the Supervisor will restart
  # us, so we can be a bit aggressive here.
  @retry_interval :timer.seconds(5)
  @max_retries 12

  def start_link(connection_module, opts) do
    GenServer.start_link(__MODULE__, connection_module, opts)
  end

  @impl true
  def init(connection_module) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)
    {:ok, %{retries: 0, connection_pid: nil, connection_module: connection_module}}
  end

  # Try to find an existing connection process or start a new one, with edge cases handled
  # to minimize false starts. During deploys, the new nodes will merge into the existing
  # cluster state and we want to minimize the window of time where we're not processing
  # messages.

  @impl true
  def handle_info(:connect, %{connection_module: connection_module, connection_pid: nil} = state) do
    Process.send_after(self(), :connect, @retry_interval)

    # First, try to link to an existing connection process
    case :global.whereis_name(connection_module) do
      :undefined ->
        # No existing process found, attempt to start one
        start_connection(state)

      pid when is_pid(pid) ->
        link_existing_pid(pid, state)
    end
  end

  def handle_info(
        {:EXIT, pid, _reason},
        %{connection_module: connection_module, connection_pid: pid} = state
      ) do
    Logger.info(
      "#{connection_module}: Replication connection died unexpectedly, restarting immediately",
      died_pid: inspect(pid),
      died_node: node(pid)
    )

    send(self(), :connect)
    {:noreply, %{state | connection_pid: nil, retries: 0}}
  end

  # Ignore exits from other unrelated processes we may be linked to
  def handle_info({:EXIT, _other_pid, _reason}, state) do
    {:noreply, state}
  end

  # Process was found, stop the retry timer
  def handle_info(:connect, state) do
    {:noreply, state}
  end

  defp start_connection(%{connection_module: connection_module} = state) do
    case connection_module.start_link(replication_child_spec(connection_module)) do
      {:ok, pid} ->
        link_existing_pid(pid, state)

      {:error, {:already_started, pid}} ->
        link_existing_pid(pid, state)

      {:error, reason} ->
        handle_start_error(reason, state)
    end
  end

  defp link_existing_pid(pid, state) do
    Process.link(pid)
    {:noreply, %{state | retries: 0, connection_pid: pid}}
  rescue
    ArgumentError ->
      handle_start_error(:link_failed, state)
  end

  defp handle_start_error(
         reason,
         %{retries: retries, connection_module: connection_module} = state
       ) do
    if retries < @max_retries do
      Logger.info("Failed to start replication connection #{connection_module}, retrying...",
        retries: retries,
        max_retries: @max_retries,
        reason: inspect(reason)
      )

      {:noreply, %{state | retries: retries + 1, connection_pid: nil}}
    else
      Logger.error(
        "Failed to start replication connection #{connection_module} after #{@max_retries} attempts, giving up!",
        reason: inspect(reason)
      )

      {:noreply, %{state | retries: -1, connection_pid: nil}}
    end
  end

  def replication_child_spec(connection_module) do
    {connection_opts, config} =
      Application.fetch_env!(:portal, connection_module)
      |> Keyword.pop(:connection_opts)

    %{
      connection_opts: connection_opts,
      instance: struct(connection_module, config)
    }
  end
end
