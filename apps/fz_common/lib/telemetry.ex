defmodule FzCommon.Telemetry do
  @moduledoc """
  Wrapper for Posthog.
  """

  require Logger

  def capture(event, metadata) do
    Logger.debug("Capturing event #{event}")
    Posthog.capture(event, metadata)
  end

  def batch(events) when is_list(events) do
    Posthog.batch(events)
  end
end
