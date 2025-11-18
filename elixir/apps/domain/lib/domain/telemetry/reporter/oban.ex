defmodule Domain.Telemetry.Reporter.Oban do
  @moduledoc """
  A simple module for reporting Oban job exceptions to Sentry.

  This reporter handles all Oban job failures and sends them to Sentry with
  contextual information. For wrapper exceptions like Domain.Entra.SyncError,
  the original exception/error is extracted and reported with additional
  attributes from the wrapper.
  """

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], measure, meta, _) do
    {exception_to_report, extra} = unwrap_exception(meta.reason, meta.job, measure)

    Sentry.capture_exception(exception_to_report, stacktrace: meta.stacktrace, extra: extra)
  end

  # Unwrap Domain.Entra.SyncError and extract the underlying cause
  defp unwrap_exception(
         %Domain.Entra.SyncError{
           reason: reason,
           cause: cause,
           directory_id: directory_id,
           step: step
         },
         job,
         measure
       ) do
    extra =
      job
      |> Map.take([:id, :args, :meta, :queue, :worker])
      |> Map.merge(measure)
      |> Map.put(:directory_id, directory_id)
      |> Map.put(:step, step)
      |> Map.put(:cause, cause)

    {reason, extra}
  end

  # For other exceptions, return as-is
  defp unwrap_exception(reason, job, measure) do
    extra =
      job
      |> Map.take([:id, :args, :meta, :queue, :worker])
      |> Map.merge(measure)

    {reason, extra}
  end
end
