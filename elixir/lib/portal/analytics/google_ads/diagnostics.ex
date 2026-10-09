defmodule Portal.Analytics.GoogleAds.Diagnostics do
  @moduledoc "Checks asynchronous Google ingestion without resubmitting conversions."
  use Oban.Worker,
    queue: :default,
    max_attempts: 26,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:request_id]]

  alias Portal.Analytics.GoogleAds
  require Logger

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(round(1800 * :math.pow(1.3, attempt)), 3600)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id}}) do
    case GoogleAds.request_status(request_id) do
      {:ok, []} -> {:error, :diagnostics_not_ready}
      {:ok, statuses} -> check_statuses(request_id, statuses)
      error -> error
    end
  end

  defp check_statuses(request_id, statuses) do
    cond do
      Enum.any?(statuses, &(&1["status"] not in ["SUCCESS", "FAILED", "PARTIAL_SUCCESS"])) ->
        {:error, :still_processing}

      Enum.any?(statuses, &(&1["status"] != "SUCCESS")) ->
        Logger.error("Google Ads conversion processing failed", request_id: request_id, diagnostics: statuses)
        {:cancel, {:processing_failed, statuses}}

      true ->
        log_success(request_id, statuses)
        :ok
    end
  end

  defp log_success(request_id, statuses) do
    if Enum.any?(statuses, &(&1["warnings"] != [])) do
      Logger.warning("Google Ads conversion processed with warnings", request_id: request_id, diagnostics: statuses)
    else
      Logger.info("Google Ads conversion processed", request_id: request_id)
    end
  end
end
