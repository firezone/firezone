defmodule Portal.Telemetry.Reporter.Oban do
  @moduledoc """
  Telemetry reporter for Oban job exceptions.

  This reporter:
  - Captures Oban job exceptions to Sentry with contextual information
  - Reports posture sync errors only when they disable the provider
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
    case safe_handle_error(meta) do
      :skip -> :ok
      context -> Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: context)
    end
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
    result = Portal.Intune.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    posture_sentry_context(result, reason, Portal.Intune.SyncError, job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Defender.Sync"} = job}) do
    result = Portal.Defender.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    posture_sentry_context(result, reason, Portal.Defender.SyncError, job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Iru.Sync"} = job}) do
    result = Portal.Iru.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    posture_sentry_context(result, reason, Portal.Iru.SyncError, job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.Santa.Sync"} = job}) do
    result = Portal.Santa.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    posture_sentry_context(result, reason, Portal.Santa.SyncError, job)
  end

  defp handle_error(%{reason: reason, job: %{worker: "Portal.SentinelOne.Sync"} = job}) do
    result = Portal.SentinelOne.ErrorHandler.handle(reason, job.args["posture_provider_id"])
    posture_sentry_context(result, reason, Portal.SentinelOne.SyncError, job)
  end

  defp handle_error(%{job: job}) do
    # Default Sentry context for jobs without a domain-specific handler
    build_sentry_context(job)
  end

  # Unexpected worker crashes remain immediately visible. Expected sync failures
  # are reported when the handler transitions the provider to disabled.
  defp posture_sentry_context(:ok, %{__struct__: sync_error}, sync_error, _job), do: :skip
  defp posture_sentry_context(_result, _reason, _sync_error, job), do: build_sentry_context(job)

  defp build_sentry_context(job) do
    Map.take(job, [:id, :args, :meta, :queue, :worker])
  end
end
