defmodule Portal.Telemetry.Reporter.Oban do
  @moduledoc """
  Telemetry reporter for Oban job exceptions.

  This reporter:
  - Captures all Oban job exceptions to Sentry with contextual information
  - Routes errors to domain-specific handlers based on worker type

  Domain handlers are responsible for:
  - Updating relevant state (e.g., directory sync status)
  - Returning Sentry context specific to their domain
  """

  @directory_sync_workers [
    "Portal.Entra.Sync",
    "Portal.Google.Sync",
    "Portal.Okta.Sync"
  ]

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], _measure, meta, _config) do
    sentry_context = handle_error(meta)

    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: sentry_context)
  end

  # Route errors to domain-specific handlers based on worker type.
  # Each handler updates relevant state and returns extra context for Sentry.
  defp handle_error(%{job: %{worker: worker}} = meta) when worker in @directory_sync_workers do
    Portal.DirectorySync.ErrorHandler.handle_error(meta)
  end

  defp handle_error(%{job: job}) do
    # Default Sentry context for jobs without a domain-specific handler
    build_sentry_context(job)
  end

  defp build_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
