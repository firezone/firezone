defmodule Domain.Telemetry.Reporter.Oban do
  @moduledoc """
  Handles errors from Oban jobs and routes them appropriately.
  """
  require Logger

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], measure, meta, _) do
    Logger.debug(inspect(meta))

    extra =
      meta.job
      |> Map.take([:id, :args, :meta, :queue, :worker])
      |> Map.merge(measure)

    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: extra)
  end
end
