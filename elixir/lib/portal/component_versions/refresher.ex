defmodule Portal.ComponentVersions.Refresher do
  use GenServer
  require Logger
  alias Portal.ComponentVersions

  @default_refresh_interval :timer.minutes(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    refresh_interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)

    {:ok, %{refresh_interval: refresh_interval, timer_ref: nil}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    refresh_versions()
    {:noreply, %{state | timer_ref: schedule_refresh(state.refresh_interval)}}
  end

  @impl true
  def handle_info(:refresh_versions, state) do
    refresh_versions()
    {:noreply, %{state | timer_ref: schedule_refresh(state.refresh_interval)}}
  end

  @impl true
  def handle_info(:force_refesh, state) do
    refresh_versions()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  defp refresh_versions do
    case ComponentVersions.fetch_versions() do
      {:ok, versions} ->
        new_config =
          Portal.Config.get_env(:portal, ComponentVersions)
          |> Keyword.merge(versions: versions)

        Application.put_env(:portal, ComponentVersions, new_config)

      {:error, reason} ->
        Logger.debug("Error fetching component versions: #{inspect(reason)}")
    end
  catch
    :exit, _reason -> :ok
  end

  defp schedule_refresh(refresh_interval) do
    Process.send_after(self(), :refresh_versions, refresh_interval)
  end
end
