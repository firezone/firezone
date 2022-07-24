defmodule FzCommon.Telemetry do
  @moduledoc """
  Wrapper for Posthog.
  """

  require Logger

  def capture(event, metadata) do
    Logger.debug("Capturing event #{event}")

    Task.start(fn ->
      # Detach from calling process to prevent blocking
      Posthog.capture(event, metadata)
    end)
  end

  def batch(events) when is_list(events) do
    Logger.debug("Capturing events #{inspect(events)}")

    Task.start(fn ->
      Posthog.batch(events)
    end)
  end
end
