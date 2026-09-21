defmodule PortalAPI.MetricsController do
  @moduledoc """
  Receives OpenTelemetry metrics exported by gateways.

  The endpoint speaks OTLP/HTTP with JSON encoding
  (https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding): the body is
  an `ExportMetricsServiceRequest` and a success is an empty
  `ExportMetricsServiceResponse`, which means every data point was accepted.
  Nothing is persisted yet; reports are logged.
  """
  use PortalAPI, :controller

  require Logger

  alias PortalAPI.ProblemDetails

  # Errors deviate from OTLP, which answers with a `google.rpc.Status`: the
  # portal speaks RFC 9457 problem details on every endpoint and gateways are
  # the only client here.
  def create(conn, params) do
    claims = conn.assigns.metrics_claims

    case data_points(params) do
      {:ok, data_points} ->
        Enum.each(data_points, &log_data_point(&1, claims))

        conn
        |> put_status(200)
        |> json(%{})

      :error ->
        ProblemDetails.send(conn, 400, "Expected an OTLP ExportMetricsServiceRequest")
    end
  end

  defp data_points(params) do
    flat_map_field(params, "resourceMetrics", fn resource_metrics ->
      flat_map_field(resource_metrics, "scopeMetrics", fn scope_metrics ->
        flat_map_field(scope_metrics, "metrics", &metric_data_points/1)
      end)
    end)
  end

  # Senders omit default values, so an absent list means no data points, which
  # is a successful (empty) export.
  defp flat_map_field(container, key, fun) when is_map(container) do
    case Map.get(container, key, []) do
      elements when is_list(elements) ->
        Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
          case fun.(element) do
            {:ok, data_points} -> {:cont, {:ok, acc ++ data_points}}
            :error -> {:halt, :error}
          end
        end)

      _other ->
        :error
    end
  end

  defp flat_map_field(_container, _key, _fun), do: :error

  # Histograms and summaries are exported by nobody here, so they are skipped
  # rather than failing the request they arrive in.
  defp metric_data_points(%{"name" => name} = metric) when is_binary(name) do
    cond do
      is_map(metric["sum"]) -> number_data_points(metric["sum"], name)
      is_map(metric["gauge"]) -> number_data_points(metric["gauge"], name)
      true -> {:ok, []}
    end
  end

  defp metric_data_points(_metric), do: :error

  defp number_data_points(kind, name) do
    flat_map_field(kind, "dataPoints", fn
      data_point when is_map(data_point) ->
        {:ok,
         [
           %{
             name: name,
             value: value(data_point),
             attributes: attributes(data_point),
             time_unix_nano: integer(Map.get(data_point, "timeUnixNano"))
           }
         ]}

      _other ->
        :error
    end)
  end

  defp value(%{"asInt" => as_int}), do: integer(as_int)
  defp value(%{"asDouble" => as_double}) when is_number(as_double), do: as_double
  defp value(_data_point), do: 0

  defp attributes(%{"attributes" => attributes}) when is_list(attributes) do
    attributes
    |> Enum.flat_map(fn
      %{"key" => key, "value" => value} when is_binary(key) -> [{key, attribute_value(value)}]
      _other -> []
    end)
    |> Map.new()
  end

  defp attributes(_data_point), do: %{}

  defp attribute_value(%{"stringValue" => value}), do: value
  defp attribute_value(%{"intValue" => value}), do: integer(value)
  defp attribute_value(%{"boolValue" => value}), do: value
  defp attribute_value(%{"doubleValue" => value}), do: value
  defp attribute_value(_value), do: nil

  # 64-bit integers are sent as decimal strings, but numbers are accepted too.
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp log_data_point(data_point, claims) do
    Logger.debug("Received gateway metric",
      account_id: claims["account_id"],
      gateway_id: claims["gateway_id"],
      site_id: claims["site_id"],
      metric: data_point.name,
      value: data_point.value,
      attributes: data_point.attributes,
      time_unix_nano: data_point.time_unix_nano
    )
  end
end
