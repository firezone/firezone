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

  require Logger

  @directory_sync_workers [
    "Portal.Entra.Sync",
    "Portal.Google.Sync",
    "Portal.Okta.Sync"
  ]

  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &__MODULE__.handle_event/4, [])
  end

  def handle_event([:oban, :job, :exception], _measure, meta, _config) do
    sentry_context = safe_handle_error(meta)

    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: sentry_context)
  end

  defp safe_handle_error(meta) do
    handle_error(meta)
  rescue
    exception ->
      Logger.error("Oban error handler crashed while building Sentry context",
        error: Exception.format(:error, exception, __STACKTRACE__)
      )

      build_sentry_context(meta.job)
  end

  # Route errors to domain-specific handlers based on worker type.
  # Each handler updates relevant state and returns extra context for Sentry.
  defp handle_error(%{job: %{worker: worker}} = meta) when worker in @directory_sync_workers do
    Portal.DirectorySync.ErrorHandler.handle_error(meta)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Intune.Sync"} = job}) do
    Portal.Intune.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    build_sentry_context(job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Defender.Sync"} = job}) do
    Portal.Defender.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    build_sentry_context(job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Iru.Sync"} = job}) do
    Portal.Iru.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    build_sentry_context(job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Santa.Sync"} = job}) do
    Portal.Santa.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    build_sentry_context(job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.SentinelOne.Sync"} = job}) do
    Portal.SentinelOne.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    build_sentry_context(job)
  end

  defp handle_error(%{job: job}) do
    # Default Sentry context for jobs without a domain-specific handler
    build_sentry_context(job)
  end

  defp build_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
