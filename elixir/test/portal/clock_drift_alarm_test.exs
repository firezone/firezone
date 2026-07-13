defmodule Portal.ClockDriftAlarmTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureLog

  alias Portal.ClockDriftAlarm

  describe "report/2" do
    test "logs an error when the database clock is more than 1s ahead" do
      now = DateTime.utc_now()

      log =
        capture_log(fn ->
          ClockDriftAlarm.report(DateTime.add(now, 1500, :millisecond), now)
        end)

      assert log =~ "System clock drifts from the database clock"
      assert log =~ "drift_ms=1500"
    end

    test "logs an error when the database clock is more than 1s behind" do
      now = DateTime.utc_now()

      log =
        capture_log(fn ->
          ClockDriftAlarm.report(DateTime.add(now, -1500, :millisecond), now)
        end)

      assert log =~ "System clock drifts from the database clock"
      assert log =~ "drift_ms=-1500"
    end

    test "stays quiet when drift is within 1s" do
      now = DateTime.utc_now()

      log =
        capture_log(fn ->
          ClockDriftAlarm.report(DateTime.add(now, 900, :millisecond), now)
        end)

      refute log =~ "System clock drifts from the database clock"
    end
  end

  describe "check/0" do
    test "compares against the live database clock without alarming" do
      log = capture_log(fn -> assert :ok = ClockDriftAlarm.check() end)
      refute log =~ "System clock drifts from the database clock"
    end
  end

  describe "start_link/1" do
    test "returns :ignore when disabled" do
      assert :ignore = ClockDriftAlarm.start_link([])
    end

    test "starts the periodic check loop when enabled" do
      Application.put_env(:portal, ClockDriftAlarm, enabled: true)
      on_exit(fn -> Application.put_env(:portal, ClockDriftAlarm, enabled: false) end)

      pid = start_supervised!(ClockDriftAlarm)
      assert Process.alive?(pid)
    end
  end

  describe "init/1" do
    test "schedules the first check" do
      assert {:ok, %{}} = ClockDriftAlarm.init([])
    end
  end

  describe "handle_info/2" do
    test ":check runs a check and keeps looping" do
      log =
        capture_log(fn ->
          assert {:noreply, %{}} = ClockDriftAlarm.handle_info(:check, %{})
        end)

      refute log =~ "System clock drifts from the database clock"
    end
  end
end
