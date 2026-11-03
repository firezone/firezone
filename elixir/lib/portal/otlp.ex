defmodule Portal.OTLP do
  @moduledoc """
  Shared configuration and transport of the portal's OTLP/HTTP exporters.
  """

  require Logger

  @azure_monitor_resource "https://monitor.azure.com/"
  @invalid_headers "OTEL_EXPORTER_OTLP_HEADERS must be a comma-separated list of key=value pairs"

  @doc """
  Returns the exporter auth option for the values of `OTLP_AUTH` and
  `OTEL_EXPORTER_OTLP_HEADERS`.

  With `OTLP_AUTH` unset, requests carry the static headers, whose values are
  percent-decoded. Raises on an unknown `OTLP_AUTH` or malformed headers.
  """
  def auth!(otlp_auth, headers) when otlp_auth in [nil, ""],
    do: {:headers, parse_headers(headers)}

  def auth!("azure-managed-identity", _headers), do: :azure_managed_identity

  def auth!(otlp_auth, _headers) do
    raise ArgumentError,
          "OTLP_AUTH must be unset or \"azure-managed-identity\", got: #{inspect(otlp_auth)}"
  end

  @doc """
  Returns `endpoint` if it is a full HTTPS URL, raises otherwise.
  """
  def validate_endpoint!(endpoint, env_var) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        endpoint

      _ ->
        raise ArgumentError, "#{env_var} must be a full HTTPS URL"
    end
  end

  @doc """
  Posts an encoded OTLP request and classifies the response for the SDK.
  """
  def post(endpoint, body, auth, req_opts) do
    opts =
      Keyword.merge(req_opts,
        body: body,
        headers: [{"content-type", "application/x-protobuf"} | headers(auth)],
        redirect: false,
        retry_log_level: false
      )

    case Req.post(endpoint, opts) do
      {:ok, %{status: status}} when status in 200..202 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("OTLP export failed", status: status)

        if status in [408, 429, 500, 502, 503, 504],
          do: :failed_retryable,
          else: :failed_not_retryable

      {:error, _reason} ->
        Logger.warning("OTLP export request failed")
        :failed_retryable
    end
  end

  defp headers({:headers, headers}), do: headers

  defp headers(:azure_managed_identity) do
    token = Portal.Azure.ManagedIdentity.access_token!(@azure_monitor_resource)
    [{"authorization", "Bearer " <> token}]
  end

  defp parse_headers(nil), do: []

  defp parse_headers(headers) do
    headers
    |> String.split(",", trim: true)
    |> Enum.map(&parse_header/1)
  end

  # Header values are typically secrets, so keep them out of the error.
  defp parse_header(header) do
    with [key, value] <- String.split(header, "=", parts: 2),
         key when key != "" <- String.trim(key) do
      {key, value |> String.trim() |> URI.decode()}
    else
      _ -> raise ArgumentError, @invalid_headers
    end
  end
end
