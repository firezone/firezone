defmodule Portal.Telemetry.DevAggregator do
  @moduledoc false

  use GenServer
  require Logger

  @report_interval_ms 30_000

  @telemetry_events [
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :channel_joined],
    [:phoenix, :channel_handled_in],
    [:portal, :repo, :query],
    [:portal, :repo, :replica, :query],
    [:portal, :repo, :web, :query],
    [:portal, :repo, :api, :query],
    [:portal, :repo, :replica, :web, :query],
    [:portal, :repo, :replica, :api, :query]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec dump() :: :ok
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  @impl true
  def init(_opts) do
    pid = self()

    :telemetry.detach("portal-dev-aggregator")

    :ok =
      :telemetry.attach_many(
        "portal-dev-aggregator",
        @telemetry_events,
        &handle_telemetry_event/4,
        %{pid: pid}
      )

    schedule_report()
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:dump, _from, state) do
    print_report(state)
    {:reply, :ok, reset_window(state)}
  end

  @impl true
  def handle_info(:report, state) do
    print_report(state)
    schedule_report()
    {:noreply, reset_window(state)}
  end

  def handle_info({:request, endpoint, route, method, status, duration_ms}, state) do
    key = {endpoint, route, method, status}

    requests =
      Map.update(
        state.requests,
        key,
        %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms},
        fn prev ->
          %{
            count: prev.count + 1,
            total_ms: prev.total_ms + duration_ms,
            min_ms: min(prev.min_ms, duration_ms),
            max_ms: max(prev.max_ms, duration_ms)
          }
        end
      )

    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:endpoint_stop, method}, state) do
    active = Map.update(state.active, method, 0, &max(&1 - 1, 0))
    {:noreply, %{state | active: active, total: state.total + 1}}
  end

  def handle_info({:active, method, delta}, state) do
    active = Map.update(state.active, method, max(delta, 0), &max(&1 + delta, 0))
    {:noreply, %{state | active: active}}
  end

  def handle_info({:db_query, duration_ms}, state) do
    db =
      case state.db do
        nil ->
          %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms}

        prev ->
          %{
            count: prev.count + 1,
            total_ms: prev.total_ms + duration_ms,
            min_ms: min(prev.min_ms, duration_ms),
            max_ms: max(prev.max_ms, duration_ms)
          }
      end

    {:noreply, %{state | db: db}}
  end

  def handle_info({:liveview_event, name, action, duration_ms}, state) do
    key = {name, action}

    liveview =
      Map.update(
        state.liveview,
        key,
        %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms},
        fn prev ->
          %{
            count: prev.count + 1,
            total_ms: prev.total_ms + duration_ms,
            min_ms: min(prev.min_ms, duration_ms),
            max_ms: max(prev.max_ms, duration_ms)
          }
        end
      )

    {:noreply, %{state | liveview: liveview}}
  end

  def handle_info({:channel_event, channel, event, duration_ms}, state) do
    key = {channel, event}

    channels =
      Map.update(
        state.channels,
        key,
        %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms},
        fn prev ->
          %{
            count: prev.count + 1,
            total_ms: prev.total_ms + duration_ms,
            min_ms: min(prev.min_ms, duration_ms),
            max_ms: max(prev.max_ms, duration_ms)
          }
        end
      )

    {:noreply, %{state | channels: channels}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("portal-dev-aggregator")
  end

  # Telemetry handler — runs in the calling process, not the GenServer

  @doc false
  def handle_telemetry_event(
        [:phoenix, :router_dispatch, :stop],
        measurements,
        metadata,
        %{pid: pid}
      ) do
    route = metadata[:route] || "(unrouted)"
    endpoint = endpoint_name(metadata.conn)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:request, endpoint, route, metadata.conn.method, metadata.conn.status || 0, duration_ms})
  end

  def handle_telemetry_event([:phoenix, :endpoint, :start], _measurements, metadata, %{pid: pid}) do
    send(pid, {:active, metadata.conn.method, 1})
  end

  def handle_telemetry_event([:phoenix, :endpoint, :stop], _measurements, metadata, %{pid: pid}) do
    send(pid, {:endpoint_stop, metadata.conn.method})
  end

  def handle_telemetry_event(
        [:phoenix, :live_view, :mount, :stop],
        measurements,
        metadata,
        %{pid: pid}
      ) do
    name = view_name(metadata.socket.view)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:liveview_event, name, "mount", duration_ms})
  end

  def handle_telemetry_event(
        [:phoenix, :live_view, :handle_params, :stop],
        measurements,
        metadata,
        %{pid: pid}
      ) do
    name = view_name(metadata.socket.view)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:liveview_event, name, "handle_params", duration_ms})
  end

  def handle_telemetry_event(
        [:phoenix, :live_view, :handle_event, :stop],
        measurements,
        metadata,
        %{pid: pid}
      ) do
    name = view_name(metadata.socket.view)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:liveview_event, name, metadata.event, duration_ms})
  end

  def handle_telemetry_event(
        [:phoenix, :live_component, :handle_event, :stop],
        measurements,
        metadata,
        %{pid: pid}
      ) do
    name = view_name(metadata.component)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:liveview_event, name, metadata.event, duration_ms})
  end

  def handle_telemetry_event([:phoenix, :channel_joined], measurements, metadata, %{pid: pid}) do
    channel = channel_name(metadata.socket.channel)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:channel_event, channel, "join", duration_ms})
  end

  def handle_telemetry_event([:phoenix, :channel_handled_in], measurements, metadata, %{pid: pid}) do
    channel = channel_name(metadata.socket.channel)
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    send(pid, {:channel_event, channel, metadata.event, duration_ms})
  end

  def handle_telemetry_event([:portal, :repo | _], measurements, _metadata, %{pid: pid}) do
    case measurements[:total_time] do
      total_time when is_integer(total_time) ->
        duration_ms = System.convert_time_unit(total_time, :native, :millisecond)
        send(pid, {:db_query, duration_ms})

      _ ->
        :ok
    end
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  defp initial_state,
    do: %{requests: %{}, active: %{}, db: nil, total: 0, channels: %{}, liveview: %{}}

  defp reset_window(state),
    do: %{state | requests: %{}, db: nil, total: 0, channels: %{}, liveview: %{}}

  defp schedule_report do
    Process.send_after(self(), :report, @report_interval_ms)
  end

  defp print_report(%{
         requests: requests,
         active: active,
         db: db,
         total: total,
         channels: channels,
         liveview: liveview
       }) do
    Logger.info(header("HTTP Requests (last 30s) — #{total} total"))

    if map_size(requests) == 0 do
      Logger.info("[metrics]   (none)")
    else
      requests
      |> Enum.sort_by(fn {{endpoint, route, method, _}, _} -> {endpoint, route, method} end)
      |> Enum.each(fn {{endpoint, route, method, status}, s} ->
        avg = div(s.total_ms, s.count)

        Logger.info(
          "[metrics]   [#{pad(endpoint, 3)}] #{pad(method, 6)} #{status}  #{pad(route, 42)}" <>
            "#{pad(s.count, 5)} reqs  avg=#{avg}ms min=#{s.min_ms}ms max=#{s.max_ms}ms"
        )
      end)
    end

    Logger.info(header("Active Requests"))

    if map_size(active) == 0 do
      Logger.info("[metrics]   (none)")
    else
      active
      |> Enum.sort()
      |> Enum.map_join("  ", fn {method, count} -> "#{method}: #{count}" end)
      |> then(&Logger.info("[metrics]   #{&1}"))
    end

    Logger.info(header("Channel Activity (last 30s)"))

    if map_size(channels) == 0 do
      Logger.info("[metrics]   (none)")
    else
      channels
      |> Enum.sort_by(fn {{channel, event}, _} -> {channel, event} end)
      |> Enum.each(fn {{channel, event}, s} ->
        avg = div(s.total_ms, s.count)

        Logger.info(
          "[metrics]   #{pad(channel, 30)} #{pad(event, 24)}" <>
            "#{pad(s.count, 5)} msgs  avg=#{avg}ms min=#{s.min_ms}ms max=#{s.max_ms}ms"
        )
      end)
    end

    Logger.info(header("LiveView Activity (last 30s)"))

    if map_size(liveview) == 0 do
      Logger.info("[metrics]   (none)")
    else
      liveview
      |> Enum.sort_by(fn {{name, action}, _} -> {name, action} end)
      |> Enum.each(fn {{name, action}, s} ->
        avg = div(s.total_ms, s.count)

        Logger.info(
          "[metrics]   #{pad(name, 36)} #{pad(action, 20)}" <>
            "#{pad(s.count, 5)} calls  avg=#{avg}ms min=#{s.min_ms}ms max=#{s.max_ms}ms"
        )
      end)
    end

    Logger.info(header("DB Queries (last 30s)"))

    case db do
      nil ->
        Logger.info("[metrics]   (none)")

      s ->
        avg = div(s.total_ms, s.count)
        Logger.info("[metrics]   #{s.count} queries  avg=#{avg}ms  min=#{s.min_ms}ms  max=#{s.max_ms}ms")
    end
  end

  @line_width 80

  defp header(title) do
    prefix = "━━━ #{title} "
    fill = String.duplicate("━", max(@line_width - String.length(prefix), 0))
    "[metrics] #{prefix}#{fill}"
  end

  defp endpoint_name(conn), do: Portal.Telemetry.endpoint_name(conn)

  defp channel_name(module) do
    module |> to_string() |> String.replace_prefix("Elixir.Portal.", "")
  end

  defp view_name(module) do
    module |> to_string() |> String.replace_prefix("Elixir.PortalWeb.", "")
  end

  defp pad(value, len) do
    str = to_string(value)
    str <> String.duplicate(" ", max(len - String.length(str), 0))
  end
end
