defmodule Portal.Telemetry.Reporter.GoogleCloudMetrics do
  @doc """
  This module implement Telemetry reporter that sends metrics to Google Cloud Monitoring API,
  with a *best effort* approach. It means that if the reporter fails to send metrics to the API,
  it will not retry, but it will keep trying to send new metrics.
  """
  use GenServer

  alias Telemetry.Metrics
  alias Portal.GoogleCloudPlatform

  require Logger

  # Maximum number of metrics a buffer can hold,
  # after this count they will be delivered or flushed right away.
  # This is bounded by the maximum number of time series points we can
  # send in a single Google Cloud Metrics API call.
  # See https://cloud.google.com/monitoring/quotas#custom_metrics_quotas
  @buffer_capacity 200

  # Maximum time in seconds to wait before flushing the buffer
  # in case it did not reach the @buffer_capacity limit within the flush interval
  @flush_interval 60
  @flush_timer :timer.seconds(@flush_interval)

  def start_link(opts) do
    project_id =
      Application.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:project_id)

    metrics = Keyword.fetch!(opts, :metrics)
    GenServer.start_link(__MODULE__, {metrics, project_id})
  end

  @impl true
  def init({metrics, project_id}) do
    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    node_name =
      System.get_env("RELEASE_NODE") ||
        Node.self()

    application_version =
      System.get_env("RELEASE_VERSION") ||
        to_string(Application.spec(:domain, :vsn))

    labels = %{node_name: node_name, application_version: application_version}

    {:ok, instance_id} = GoogleCloudPlatform.fetch_instance_id()
    {:ok, zone} = GoogleCloudPlatform.fetch_instance_zone()

    resource = %{
      "type" => "gce_instance",
      "labels" => %{
        "project_id" => project_id,
        "instance_id" => instance_id,
        "zone" => zone
      }
    }

    events =
      for {event, metrics} <- groups do
        id = {__MODULE__, event, self()}
        :telemetry.attach(id, event, &__MODULE__.handle_event/4, {metrics, self()})
        event
      end

    Process.send_after(self(), :flush, @flush_timer)

    {:ok, {events, project_id, {resource, labels}, {0, %{}}}}
  end

  @impl true
  def terminate(_, {events, _project_id, _resource_and_labels, {_buffer_length, _buffer}}) do
    for event <- events do
      :telemetry.detach({__MODULE__, event, self()})
    end

    :ok
  end

  ## Metrics aggregation and delivery

  @impl true
  def handle_info(
        {:compressed_metrics, compressed},
        {events, project_id, {resource, labels}, {buffer_length, buffer}}
      ) do
    # Process each metric and flush if we hit capacity
    {final_buffer_length, final_buffer} =
      Enum.reduce(
        compressed,
        {buffer_length, buffer},
        fn {schema, name, tags, at, measurement, unit}, {acc_buffer_length, acc_buffer} ->
          # Check if we need to flush before adding this metric
          {acc_buffer_length, acc_buffer} =
            if acc_buffer_length >= @buffer_capacity do
              flush(project_id, resource, labels, {acc_buffer_length, acc_buffer})
            else
              {acc_buffer_length, acc_buffer}
            end

          # Add the metric to buffer
          {increment, updated_buffer} =
            Map.get_and_update(acc_buffer, {schema, name, tags, unit}, fn prev_value ->
              buffer(schema, prev_value, at, measurement)
            end)

          {acc_buffer_length + increment, updated_buffer}
        end
      )

    {:noreply, {events, project_id, {resource, labels}, {final_buffer_length, final_buffer}}}
  end

  def handle_info(:flush, {events, project_id, {resource, labels}, {buffer_length, buffer}}) do
    {buffer_length, buffer} =
      if all_intervals_greater_than_5s?(buffer) do
        flush(project_id, resource, labels, {buffer_length, buffer})
      else
        {buffer_length, buffer}
      end

    # Stagger API calls
    jitter = :rand.uniform(2000)

    Process.send_after(self(), :flush, @flush_timer + jitter)
    {:noreply, {events, project_id, {resource, labels}, {buffer_length, buffer}}}
  end

  # Google Cloud Monitoring API does not support sampling intervals shorter than 5 seconds
  defp all_intervals_greater_than_5s?(buffer) do
    Enum.all?(buffer, &interval_greater_than_5s?/1)
  end

  defp interval_greater_than_5s?({{schema, _name, _tags, _unit}, _measurements})
       when schema in [Metrics.Counter, Metrics.Sum, Metrics.LastValue],
       do: true

  # Only Distribution and Summary metrics use intervals
  defp interval_greater_than_5s?({{schema, _name, _tags, _unit}, {started_at, ended_at, _}})
       when schema in [Metrics.Distribution, Metrics.Summary] do
    # Sometimes we receive a DateTime struct, sometimes an ISO8601 string :-(
    started_at =
      if is_binary(started_at) do
        {:ok, parsed, _} = DateTime.from_iso8601(started_at)
        parsed
      else
        started_at
      end

    ended_at =
      if is_binary(ended_at) do
        {:ok, parsed, _} = DateTime.from_iso8601(ended_at)
        parsed
      else
        ended_at
      end

    DateTime.diff(ended_at, started_at, :second) > 5
  end

  # counts the total number of emitted events
  defp buffer(Metrics.Counter, nil, at, _measurement) do
    {1, {at, at, 1}}
  end

  defp buffer(Metrics.Counter, {started_at, _ended_at, num}, ended_at, _measurement) do
    {0, {started_at, ended_at, num + 1}}
  end

  # builds a histogram of selected measurement
  defp buffer(Metrics.Distribution, nil, at, measurement) do
    buckets = init_buckets() |> update_buckets(measurement)
    {1, {at, at, {1, measurement, measurement, measurement, 0, buckets}}}
  end

  defp buffer(
         Metrics.Distribution,
         {started_at, _ended_at, {count, sum, min, max, squared_deviation_sum, buckets}},
         ended_at,
         measurement
       ) do
    count = count + 1
    sum = sum + measurement
    min = min(min, measurement)
    max = max(max, measurement)
    mean = sum / count
    deviation = measurement - mean
    squared_deviation_sum = squared_deviation_sum + :math.pow(deviation, 2)
    buckets = update_buckets(buckets, measurement)

    {0, {started_at, ended_at, {count, sum, min, max, squared_deviation_sum, buckets}}}
  end

  # keeps track of the sum of selected measurement
  defp buffer(Metrics.Sum, nil, at, measurement) do
    {1, {at, at, measurement}}
  end

  defp buffer(Metrics.Sum, {started_at, _ended_at, sum}, ended_at, measurement) do
    {0, {started_at, ended_at, sum + measurement}}
  end

  # calculating statistics of the selected measurement, like maximum, mean, percentiles etc
  # since google does not support more than one metric point per 5 seconds we must aggregate them
  defp buffer(Metrics.Summary, nil, at, measurement) do
    buckets = init_buckets() |> update_buckets(measurement)
    {1, {at, at, {1, measurement, measurement, measurement, 0, buckets}}}
  end

  defp buffer(
         Metrics.Summary,
         {started_at, _ended_at, {count, sum, min, max, squared_deviation_sum, buckets}},
         ended_at,
         measurement
       ) do
    count = count + 1
    sum = sum + measurement
    min = min(min, measurement)
    max = max(max, measurement)
    mean = sum / count
    deviation = measurement - mean
    squared_deviation_sum = squared_deviation_sum + :math.pow(deviation, 2)
    buckets = update_buckets(buckets, measurement)

    {0, {started_at, ended_at, {count, sum, min, max, squared_deviation_sum, buckets}}}
  end

  # holding the value of the selected measurement from the most recent event
  defp buffer(Metrics.LastValue, nil, at, measurement) do
    {1, {at, at, measurement}}
  end

  defp buffer(Metrics.LastValue, {started_at, _ended_at, _measurement}, ended_at, measurement) do
    {0, {started_at, ended_at, measurement}}
  end

  defp init_buckets do
    # add an underflow bucket
    %{0 => 0}
  end

  # We use exponential bucketing for histograms and distributions
  defp update_buckets(buckets, measurement) do
    # Determine the nearest power of 2 for the measurement
    power_of_2 =
      if measurement <= 0 do
        0
      else
        :math.pow(2, :math.ceil(:math.log2(measurement)))
      end

    # put measurement into this bucket
    Map.update(buckets, trunc(power_of_2), 1, &(&1 + 1))
  end

  defp bucket_counts(buckets) do
    value_buckets =
      buckets
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_bucket, count} ->
        count
      end)

    # append an overflow bucket which will be empty
    value_buckets ++ [0]
  end

  defp flush(
         project_id,
         resource,
         labels,
         {buffer_length, buffer}
       ) do
    time_series =
      buffer
      |> Enum.flat_map(fn {{schema, name, tags, unit}, measurements} ->
        labels = Map.merge(labels, tags) |> truncate_labels()
        format_time_series(schema, name, labels, resource, measurements, unit)
      end)

    case GoogleCloudPlatform.send_metrics(project_id, time_series) do
      :ok ->
        {0, %{}}

      {:error, reason} ->
        # Will happen for both 4xx and 5xx errors. Metrics aren't critical, so just reset
        # the buffer to avoid filling it in case Google API is down.
        Logger.warning("Failed to send metrics to Google Cloud, dropping buffer",
          reason: inspect(reason),
          time_series: inspect(time_series),
          buffer_length: buffer_length,
          buffer: inspect(buffer)
        )

        {0, %{}}
    end
  end

  defp truncate_labels(labels) do
    for {k, v} <- labels, into: %{} do
      {k, v |> to_string() |> truncate_label()}
    end
  end

  defp truncate_label(value) when byte_size(value) > 1020,
    do: String.slice(value, 0, 1020) <> "..."

  defp truncate_label(value),
    do: value

  defp format_time_series(Metrics.Counter, name, labels, resource, measurements, unit) do
    {started_at, ended_at, count} = measurements

    [
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/count",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "CUMULATIVE",
        valueType: "INT64",
        points: [
          %{
            interval: format_interval(started_at, ended_at),
            value: %{"int64Value" => count}
          }
        ]
      }
    ]
  end

  # builds a histogram of selected measurement
  defp format_time_series(Metrics.Distribution, name, labels, resource, measurements, unit) do
    {started_at, ended_at, {count, sum, _min, _max, squared_deviation_sum, buckets}} =
      measurements

    [
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/distribution",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "CUMULATIVE",
        valueType: "DISTRIBUTION",
        points: [
          %{
            interval: format_interval(started_at, ended_at),
            value: %{
              "distributionValue" => %{
                "count" => count,
                "mean" => sum / count,
                "sumOfSquaredDeviation" => squared_deviation_sum,
                "bucketOptions" => %{
                  "exponentialBuckets" => %{
                    "numFiniteBuckets" => Enum.count(buckets),
                    "growthFactor" => 2,
                    "scale" => 1
                  }
                },
                "bucketCounts" => bucket_counts(buckets)
              }
            }
          }
        ]
      }
    ]
  end

  # keeps track of the sum of selected measurement
  defp format_time_series(Metrics.Sum, name, labels, resource, measurements, unit) do
    {started_at, ended_at, sum} = measurements

    [
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/sum",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "CUMULATIVE",
        valueType: "DOUBLE",
        points: [
          %{
            interval: format_interval(started_at, ended_at),
            value: %{"doubleValue" => sum}
          }
        ]
      }
    ]
  end

  # calculating statistics of the selected measurement, like maximum, mean, percentiles etc
  defp format_time_series(Metrics.Summary, name, labels, resource, measurements, unit) do
    {started_at, ended_at, {count, sum, min, max, squared_deviation_sum, buckets}} = measurements

    [
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/summary",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "CUMULATIVE",
        valueType: "DISTRIBUTION",
        points: [
          %{
            interval: format_interval(started_at, ended_at),
            value: %{
              "distributionValue" => %{
                "count" => count,
                "mean" => sum / count,
                "sumOfSquaredDeviation" => squared_deviation_sum,
                "bucketOptions" => %{
                  "exponentialBuckets" => %{
                    "numFiniteBuckets" => Enum.count(buckets),
                    "growthFactor" => 2,
                    "scale" => 1
                  }
                },
                "bucketCounts" => bucket_counts(buckets)
              }
            }
          }
        ]
      },
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/min_val",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "GAUGE",
        valueType: "DOUBLE",
        points: [
          %{
            interval: %{"endTime" => ended_at},
            value: %{"doubleValue" => min}
          }
        ]
      },
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/max_val",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "GAUGE",
        valueType: "DOUBLE",
        points: [
          %{
            interval: %{"endTime" => ended_at},
            value: %{"doubleValue" => max}
          }
        ]
      }
    ]
  end

  # holding the value of the selected measurement from the most recent event
  defp format_time_series(Metrics.LastValue, name, labels, resource, measurements, unit) do
    {_started_at, ended_at, last_value} = measurements

    [
      %{
        metric: %{
          type: "custom.googleapis.com/elixir/#{Enum.join(name, "/")}/last_value",
          labels: labels
        },
        resource: resource,
        unit: to_string(unit),
        metricKind: "GAUGE",
        valueType: "DOUBLE",
        points: [
          %{
            interval: %{"endTime" => ended_at},
            value: %{"doubleValue" => last_value}
          }
        ]
      }
    ]
  end

  defp format_interval(at, at) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    %{"startTime" => at, "endTime" => now}
  end

  defp format_interval(started_at, ended_at) do
    %{"startTime" => started_at, "endTime" => ended_at}
  end

  ## Telemetry handlers

  @doc false
  def handle_event(_event_name, measurements, metadata, {metrics, aggregator_pid}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    compressed_metrics =
      for %schema{} = metric <- metrics,
          keep?(metric, metadata),
          measurement = extract_measurement(metric, measurements, metadata) do
        tags = extract_tags(metric, metadata)
        {schema, metric.name, tags, now, measurement, metric.unit}
      end

    send(aggregator_pid, {:compressed_metrics, compressed_metrics})

    :ok
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end
end
