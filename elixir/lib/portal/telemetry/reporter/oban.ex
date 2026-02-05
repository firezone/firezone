defmodule Portal.Telemetry.Reporter.Oban do
  @moduledoc """
  Telemetry reporter for Oban job exceptions.

  This reporter:
  - Captures all Oban job exceptions to Sentry with contextual information
  - Routes errors to provider-specific SyncError handlers based on worker type
  """

  @sync_worker_error_handlers %{
    "Portal.Entra.Sync" => Portal.Entra.SyncError,
    "Portal.Google.Sync" => Portal.Google.SyncError,
    "Portal.Okta.Sync" => Portal.Okta.SyncError
  }

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], _measure, meta, _config) do
    sentry_context = handle_error(meta)

    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: sentry_context)
  end

  # Route errors to provider-specific SyncError handlers based on worker type.
  # Each handler classifies the error, updates directory state, and returns Sentry context.
  defp handle_error(%{job: %{worker: worker}} = meta) do
    case Map.get(@sync_worker_error_handlers, worker) do
      nil -> build_default_sentry_context(meta.job)
      handler -> handler.handle_error(meta)
    end
  end

  defp build_default_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
