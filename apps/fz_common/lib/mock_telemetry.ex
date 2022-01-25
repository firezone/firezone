defmodule FzCommon.MockTelemetry do
  @moduledoc """
  Mock Posthog wrapper.
  """

  def capture(_event, _metadata) do
    {}
  end

  def batch(events) when is_list(events) do
  end
end
