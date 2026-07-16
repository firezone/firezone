defmodule Portal.Telemetry.ToggleTest do
  # Separated from telemetry_test.exs because enable_metrics/1 and disable_metrics/1
  # call :telemetry.attach_many/:telemetry.detach, which mutate a global ETS table.
  # Running these tests alongside async: true tests causes races on handler state.
  use ExUnit.Case, async: false

  setup do
    Portal.Telemetry.disable_metrics(:liveview_events)
    on_exit(fn -> Portal.Telemetry.disable_metrics(:liveview_events) end)
  end

  describe "enable_metrics/1, disable_metrics/1, metrics_enabled?/1, enabled_metrics/0" do
    test "liveview_events is disabled after calling disable_metrics/1" do
      refute Portal.Telemetry.metrics_enabled?(:liveview_events)
    end

    test "enable_metrics/1 returns :ok and enables the group" do
      assert :ok = Portal.Telemetry.enable_metrics(:liveview_events)
      assert Portal.Telemetry.metrics_enabled?(:liveview_events)
    end

    test "enable_metrics/1 returns :already_enabled when group is already enabled" do
      Portal.Telemetry.enable_metrics(:liveview_events)
      assert {:error, :already_enabled} = Portal.Telemetry.enable_metrics(:liveview_events)
    end

    test "disable_metrics/1 disables the group" do
      Portal.Telemetry.enable_metrics(:liveview_events)
      assert :ok = Portal.Telemetry.disable_metrics(:liveview_events)
      refute Portal.Telemetry.metrics_enabled?(:liveview_events)
    end

    test "enable_metrics/1 returns :unknown_group for unknown group" do
      assert {:error, :unknown_group} = Portal.Telemetry.enable_metrics(:nonexistent)
    end

    test "disable_metrics/1 returns :unknown_group for unknown group" do
      assert {:error, :unknown_group} = Portal.Telemetry.disable_metrics(:nonexistent)
    end

    test "metrics_enabled?/1 returns false for unknown group" do
      refute Portal.Telemetry.metrics_enabled?(:nonexistent)
    end

    test "enabled_metrics/0 excludes disabled groups" do
      Portal.Telemetry.enable_metrics(:liveview_events)
      enabled = Portal.Telemetry.enabled_metrics()
      assert :liveview_events in enabled

      Portal.Telemetry.disable_metrics(:liveview_events)
      enabled = Portal.Telemetry.enabled_metrics()
      refute :liveview_events in enabled
    end

    test "enable_metrics/1 wires handler so telemetry events are processed" do
      assert :ok = Portal.Telemetry.enable_metrics(:liveview_events)

      :telemetry.execute(
        [:phoenix, :live_view, :handle_event, :stop],
        %{duration: 1_000},
        %{socket: %{view: PortalWeb.SignInLive}, event: "save", params: %{}}
      )

      # telemetry detaches handlers that raise, so still being enabled proves
      # the handler ran successfully against a real event dispatch
      assert Portal.Telemetry.metrics_enabled?(:liveview_events)
    end

    test "disable_metrics/1 removes handler so telemetry events are no longer processed" do
      Portal.Telemetry.enable_metrics(:liveview_events)
      Portal.Telemetry.disable_metrics(:liveview_events)

      handlers = :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :stop])
      refute Enum.any?(handlers, &(&1.id == "portal-liveview-event-metrics"))
    end
  end
end
