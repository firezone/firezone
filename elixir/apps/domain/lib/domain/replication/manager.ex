defmodule Domain.Replication.Manager do
  @moduledoc """
    Manages the Postgrex.ReplicationConnection to ensure that we always have one running to prevent
    unbounded growth of the WAL log and ensure we are processing events.
  """
  use GenServer
  require Logger

  @retry_interval :timer.seconds(30)

  # Should be enough to gracefully handle transient network issues and DB restarts,
  # but not too long to avoid broadcasting needed events.
  @max_retries 10

  def start_link(connection_module, opts) do
    GenServer.start_link(__MODULE__, connection_module, opts)
  end

  @impl true
  def init(connection_module) do
    send(self(), {:connect, connection_module})

    {:ok, %{retries: 0}}
  end

  @impl true
  def handle_info({:connect, connection_module}, %{retries: retries} = state) do
    Process.send_after(self(), {:connect, connection_module}, @retry_interval)

    case connection_module.start_link(replication_child_spec(connection_module)) do
      {:ok, _pid} ->
        # Our process won
        {:noreply, %{state | retries: 0}}

      {:error, {:already_started, _pid}} ->
        # Another process already started the connection
        {:noreply, %{state | retries: 0}}

      {:error, reason} ->
        if retries < @max_retries do
          Logger.info("Failed to start replication connection #{connection_module}",
            retries: retries,
            max_retries: @max_retries,
            reason: inspect(reason)
          )

          {:noreply, %{state | retries: retries + 1}}
        else
          Logger.error(
            "Failed to start replication connection #{connection_module} after #{@max_retries} attempts, giving up!",
            reason: inspect(reason)
          )

          # Let the supervisor restart us
          {:stop, :normal, state}
        end
    end
  end

  def replication_child_spec(connection_module) do
    {connection_opts, config} =
      Application.fetch_env!(:domain, connection_module)
      |> Keyword.pop(:connection_opts)

    %{
      connection_opts: connection_opts,
      instance: struct(connection_module, config)
    }
  end
end
