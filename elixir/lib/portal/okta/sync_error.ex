defmodule Portal.Okta.SyncError do
  @moduledoc """
  Exception raised when Okta directory sync fails.

  This exception is captured by the Oban telemetry reporter and sent to Sentry
  with full context about the directory and the failure reason.
  """

  defexception [:message, :error, :directory_id, :step]

  @impl true
  def exception(opts) do
    error = Keyword.get(opts, :error)
    directory_id = Keyword.fetch!(opts, :directory_id)
    step = Keyword.fetch!(opts, :step)

    message = build_message(error, directory_id, step)

    %__MODULE__{
      message: message,
      error: error,
      directory_id: directory_id,
      step: step
    }
  end

  defp build_message(error, directory_id, step) when is_binary(error) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{error}"
  end

  defp build_message({tag, msg}, directory_id, step) when is_atom(tag) and is_binary(msg) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{tag}: #{msg}"
  end

  defp build_message(%{status: status, body: body}, directory_id, step) when is_integer(status) do
    "Okta sync failed for directory #{directory_id} at #{step}: HTTP #{status} - #{inspect(body)}"
  end

  defp build_message(%{__exception__: true} = exception, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{Exception.message(exception)}"
  end

  defp build_message(error, directory_id, step) do
    "Okta sync failed for directory #{directory_id} at #{step}: #{inspect(error)}"
  end
end
