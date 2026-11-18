defmodule Portal.OTLP do
  @moduledoc """
  Shared transport of the portal's OTLP/HTTP exporters.
  """

  require Logger

  @azure_monitor_resource "https://monitor.azure.com/"
  @retryable_statuses [408, 429, 500, 502, 503, 504]

  @doc """
  Posts an encoded OTLP request and classifies the response for the SDK.
  """
  def post(endpoint, body, auth, req_opts) do
    opts =
      [retry: &retry?/2]
      |> Keyword.merge(req_opts)
      |> Keyword.merge(
        body: body,
        headers: [{"content-type", "application/x-protobuf"} | headers(auth)],
        redirect: false,
        retry_log_level: false
      )

    case Req.post(endpoint, opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("OTLP export failed", status: status)

        if status in @retryable_statuses,
          do: :failed_retryable,
          else: :failed_not_retryable

      {:error, reason} ->
        Logger.warning("OTLP export request failed", reason: error_message(reason))
        :failed_retryable
    end
  end

  # Req's `:transient` mode, plus failed DNS lookups: the ingestion endpoint's
  # records have short TTLs, so resolver blips would otherwise drop batches.
  defp retry?(_request, %Req.Response{status: status}), do: status in @retryable_statuses

  defp retry?(_request, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed, :nxdomain]

  defp retry?(_request, %Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:unprocessed, :pool_not_available]

  defp retry?(_request, _exception), do: false

  defp error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_message(reason), do: inspect(reason)

  defp headers({:headers, headers}), do: headers

  defp headers(:azure_managed_identity) do
    token = Portal.Azure.ManagedIdentity.access_token!(@azure_monitor_resource)
    [{"authorization", "Bearer " <> token}]
  end
end
