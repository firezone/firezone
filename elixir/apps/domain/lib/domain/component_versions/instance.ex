defmodule Domain.ComponentVersions.Instance do
  use GenServer
  require Logger
  alias Domain.ComponentVersions

  @ets_table_name __MODULE__.ETS
  @default_refresh_interval :timer.minutes(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)

    table =
      :ets.new(@ets_table_name, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: false
      ])

    {:ok, %{table: table, refresh_interval: refresh_interval}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    refresh_versions()
    :ok = schedule_refresh(state.refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_versions, state) do
    refresh_versions()
    :ok = schedule_refresh(state.refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:force_refesh, state) do
    refresh_versions()
    {:noreply, state}
  end

  def component_version(component) do
    case :ets.lookup(@ets_table_name, component) do
      [] -> "0.0.0"
      [{_key, value}] -> value
    end
  end

  defp refresh_versions do
    case ComponentVersions.fetch_versions() do
      {:ok, versions} ->
        Enum.each(versions, fn kv -> :ets.insert(@ets_table_name, kv) end)

      {:error, reason} ->
        Logger.debug("Error fetching component versions: #{inspect(reason)}")
    end
  end

  defp schedule_refresh(refresh_interval) do
    Process.send_after(self(), :refresh_versions, refresh_interval)
    :ok
  end
end
