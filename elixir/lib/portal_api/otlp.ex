defmodule PortalAPI.OTLP do
  @moduledoc """
  Decodes the OTLP/HTTP JSON payloads gateways export metrics in.

  The mapping is the one the OTLP spec pins
  (https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding): keys are
  lowerCamelCase, 64-bit values and timestamps are decimal strings (numbers are
  accepted too), enums are integers, and unknown fields are ignored. Senders
  omit default values, so an absent field reads as zero or empty.
  """

  @type data_point :: %{
          name: String.t(),
          value: number() | nil,
          attributes: %{String.t() => term()},
          time_unix_nano: integer() | nil
        }

  @doc """
  Returns the data points of an `ExportMetricsServiceRequest`.

  Errs on a body that is not one; a body carrying no data points, or only metric
  kinds we do not read, is an empty export rather than an error.
  """
  @spec data_points(map()) :: {:ok, [data_point()]} | :error
  def data_points(request) do
    flat_map_field(request, "resourceMetrics", fn resource_metrics ->
      flat_map_field(resource_metrics, "scopeMetrics", fn scope_metrics ->
        flat_map_field(scope_metrics, "metrics", &metric_data_points/1)
      end)
    end)
  end

  defp flat_map_field(container, key, fun) when is_map(container) do
    case Map.get(container, key, []) do
      elements when is_list(elements) -> flat_map(elements, fun)
      _other -> :error
    end
  end

  defp flat_map_field(_container, _key, _fun), do: :error

  defp flat_map(elements, fun) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, data_points} -> {:cont, {:ok, acc ++ data_points}}
        :error -> {:halt, :error}
      end
    end)
  end

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

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil
end
