defmodule PortalAPI.OTLPMetricsController do
  @moduledoc """
  OTLP/HTTP metrics receiver for Clients and Gateways, forwarding to Azure Monitor.

  The forwarded request is rebuilt from the decoded body, keeping only the
  metrics the token allows and a fixed set of resource attributes. Attributes
  under `firezone.` are reserved for the account identity stamped from the
  token, so a reporter cannot attribute metrics to another account.
  """
  use PortalAPI, :controller

  alias Portal.Azure.MetricsExporter
  alias Portal.MetricsToken
  alias PortalAPI.ProblemDetails

  @pb :opentelemetry_exporter_metrics_service_pb
  @max_body_bytes 1_000_000
  @resource_attributes ~w[service.name service.version service.instance.id os.type]
  @reserved_attribute_prefix "firezone."

  def create(conn, _params) do
    claims = conn.assigns.metrics_claims

    with :ok <- ensure_protobuf(conn),
         {:ok, body, conn} <- read_body_within_limit(conn),
         {:ok, request} <- decode(body) do
      request
      |> sanitize(claims)
      |> forward(conn)
    else
      {:error, :unsupported_media_type} ->
        ProblemDetails.send(conn, 415, "Expected an uncompressed application/x-protobuf body")

      {:error, :too_large} ->
        ProblemDetails.send(conn, 413, "Request body exceeds #{@max_body_bytes} bytes")

      {:error, :undecodable} ->
        ProblemDetails.send(conn, 400, "Expected an ExportMetricsServiceRequest")
    end
  end

  defp ensure_protobuf(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "x-protobuf", _params} <- Plug.Conn.Utils.content_type(content_type),
         encoding when encoding in [[], ["identity"]] <- get_req_header(conn, "content-encoding") do
      :ok
    else
      _ -> {:error, :unsupported_media_type}
    end
  end

  defp read_body_within_limit(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _reason} -> {:error, :undecodable}
    end
  end

  defp decode(body) do
    {:ok, @pb.decode_msg(body, :export_metrics_service_request)}
  rescue
    _ -> {:error, :undecodable}
  end

  defp sanitize(request, claims) do
    identity = [
      string_attribute("firezone.account.id", claims["account_id"]),
      string_attribute("firezone.account.slug", claims["account_slug"])
    ]

    resource_metrics =
      request
      |> Map.get(:resource_metrics, [])
      |> Enum.map(&sanitize_resource_metrics(&1, identity, claims))
      |> Enum.reject(&(&1.scope_metrics == []))

    %{resource_metrics: resource_metrics}
  end

  defp sanitize_resource_metrics(resource_metrics, identity, claims) do
    reported_attributes =
      resource_metrics
      |> Map.get(:resource, %{})
      |> Map.get(:attributes, [])
      |> Enum.filter(&(&1.key in @resource_attributes and string_value?(&1)))

    scope_metrics =
      resource_metrics
      |> Map.get(:scope_metrics, [])
      |> Enum.map(&sanitize_scope_metrics(&1, claims))
      |> Enum.reject(&(&1.metrics == []))

    %{resource: %{attributes: identity ++ reported_attributes}, scope_metrics: scope_metrics}
  end

  defp sanitize_scope_metrics(scope_metrics, claims) do
    metrics =
      scope_metrics
      |> Map.get(:metrics, [])
      |> Enum.filter(&(Map.has_key?(&1, :data) and MetricsToken.allows?(claims, &1.name)))
      |> Enum.map(&sanitize_metric/1)

    case Map.get(scope_metrics, :scope) do
      %{name: name, version: version} -> %{scope: %{name: name, version: version}, metrics: metrics}
      _ -> %{metrics: metrics}
    end
  end

  defp sanitize_metric(%{data: {kind, data}} = metric) do
    data = Map.update(data, :data_points, [], &Enum.map(&1, fn point -> sanitize_point(point) end))

    %{name: metric.name, description: metric.description, unit: metric.unit, data: {kind, data}}
  end

  defp sanitize_point(point) do
    point
    |> Map.update(:attributes, [], &Enum.reject(&1, fn a -> reserved?(a.key) end))
    |> Map.replace(:exemplars, [])
  end

  defp forward(%{resource_metrics: []}, conn), do: send_export_response(conn)

  defp forward(request, conn) do
    endpoint = Portal.Config.fetch_env!(:portal, :azure_otlp_metrics_endpoint)
    body = @pb.encode_msg(request, :export_metrics_service_request)

    case MetricsExporter.post(endpoint, body) do
      :ok -> send_export_response(conn)
      :failed_retryable -> ProblemDetails.send(conn, 503, "Metrics could not be forwarded")
      :failed_not_retryable -> ProblemDetails.send(conn, 500, "Metrics could not be forwarded")
    end
  end

  defp send_export_response(conn) do
    conn
    |> put_resp_content_type("application/x-protobuf", nil)
    |> send_resp(200, @pb.encode_msg(%{}, :export_metrics_service_response))
  end

  defp string_attribute(key, value), do: %{key: key, value: %{value: {:string_value, value}}}

  defp string_value?(%{value: %{value: {:string_value, _}}}), do: true
  defp string_value?(_attribute), do: false

  defp reserved?(key), do: String.starts_with?(key, @reserved_attribute_prefix)
end
