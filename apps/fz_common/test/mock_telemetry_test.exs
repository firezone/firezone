defmodule FzCommon.MockTelemetryTest do
  use ExUnit.Case, async: true

  alias FzCommon.MockTelemetry

  describe "capture/2" do
    test "returns tuple" do
      assert is_tuple(MockTelemetry.capture(:noop, :noop))
    end
  end

  describe "batch/1" do
    test "returns tuple" do
      assert is_tuple(MockTelemetry.batch([:noop]))
    end
  end
end
