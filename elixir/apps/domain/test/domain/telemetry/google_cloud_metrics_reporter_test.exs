defmodule Domain.Telemetry.GoogleCloudMetricsReporterTest do
  use ExUnit.Case, async: true
  import Domain.Telemetry.GoogleCloudMetricsReporter
  alias Domain.Mocks.GoogleCloudPlatform

  describe "handle_info/2 for :compressed_metrics" do
    test "aggregates and delivers Metrics.Counter metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      assert {:noreply, {[], "proj", %{type: "test"}, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", %{type: "test"}, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, 1}
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, one_minute_ago, 1.1,
                     :request}
                  ]},
                 state
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago, 2}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/count",
                     "labels" => %{"foo" => "bar"}
                   },
                   "resource" => %{"type" => "test"},
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "INT64",
                   "unit" => "request",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago),
                         "startTime" => DateTime.to_iso8601(two_minutes_ago)
                       },
                       "value" => %{"int64Value" => 2}
                     }
                   ]
                 }
               ]
             }
    end

    test "aggregates and delivers Metrics.Distribution metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      assert {:noreply, {[], "proj", %{type: "test"}, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, two_minutes_ago,
                     5.5, :request}
                  ]},
                 {[], "proj", %{type: "test"}, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, {1, 5.5, 5.5, 5.5, 0}}
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, one_minute_ago,
                     11.3, :request}
                  ]},
                 state
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago, {2, 16.8, 5.5, 11.3, 8.410000000000002}}
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, one_minute_ago,
                     -1, :request}
                  ]},
                 state
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago, {3, 15.8, -1, 11.3, 47.681111111111115}}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/distribution",
                     "labels" => %{"foo" => "bar"}
                   },
                   "resource" => %{"type" => "test"},
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DISTRIBUTION",
                   "unit" => "request",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago),
                         "startTime" => DateTime.to_iso8601(two_minutes_ago)
                       },
                       "value" => %{
                         "distributionValue" => %{
                           "count" => 3,
                           "mean" => 5.266666666666667,
                           "range" => %{"max" => 11.3, "min" => -1},
                           "sumOfSquaredDeviation" => 47.681111111111115
                         }
                       }
                     }
                   ]
                 }
               ]
             }
    end

    test "aggregates and delivers Metrics.Sum metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      assert {:noreply, {[], "proj", %{type: "test"}, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Sum, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", %{type: "test"}, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Sum, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, 1}
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Sum, [:foo], %{"foo" => "bar"}, one_minute_ago, 2.19,
                     :request}
                  ]},
                 state
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Sum, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago, 3.19}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/sum",
                     "labels" => %{"foo" => "bar"}
                   },
                   "resource" => %{"type" => "test"},
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DOUBLE",
                   "unit" => "request",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago),
                         "startTime" => DateTime.to_iso8601(two_minutes_ago)
                       },
                       "value" => %{"doubleValue" => 3.19}
                     }
                   ]
                 }
               ]
             }
    end

    test "aggregates and delivers Metrics.Summary metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      assert {:noreply, {[], "proj", %{type: "test"}, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, two_minutes_ago, 5.5,
                     :request}
                  ]},
                 {[], "proj", %{type: "test"}, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, :request} => [
                 {two_minutes_ago, 5.5}
               ]
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, one_minute_ago, 11.3,
                     :request}
                  ]},
                 state
               )

      assert buffer_size == 2

      assert buffer == %{
               {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, :request} => [
                 {one_minute_ago, 11.3},
                 {two_minutes_ago, 5.5}
               ]
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/values",
                     "labels" => %{"foo" => "bar"}
                   },
                   "resource" => %{"type" => "test"},
                   "metricKind" => "GAUGE",
                   "valueType" => "DOUBLE",
                   "unit" => "request",
                   "points" => [
                     %{
                       "interval" => %{"endTime" => DateTime.to_iso8601(two_minutes_ago)},
                       "value" => %{"doubleValue" => 5.5}
                     },
                     %{
                       "interval" => %{"endTime" => DateTime.to_iso8601(one_minute_ago)},
                       "value" => %{"doubleValue" => 11.3}
                     }
                   ]
                 }
               ]
             }
    end

    test "aggregates and delivers Metrics.LastValue metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      assert {:noreply, {[], "proj", %{type: "test"}, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.LastValue, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", %{type: "test"}, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.LastValue, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, 1}
             }

      assert {:noreply, {_, _, _, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.LastValue, [:foo], %{"foo" => "bar"}, one_minute_ago, -1,
                     :request}
                  ]},
                 state
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.LastValue, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago, -1}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/last_value",
                     "labels" => %{"foo" => "bar"}
                   },
                   "resource" => %{"type" => "test"},
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DOUBLE",
                   "unit" => "request",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago),
                         "startTime" => DateTime.to_iso8601(two_minutes_ago)
                       },
                       "value" => %{"doubleValue" => -1}
                     }
                   ]
                 }
               ]
             }
    end

    test "submits the metrics to Google Cloud when buffer is filled" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()

      {_, _, _, {buffer_size, buffer}} =
        Enum.reduce(1..1001, {[], "proj", %{type: "test"}, {0, %{}}}, fn i, state ->
          assert {:noreply, state} =
                   handle_info(
                     {:compressed_metrics,
                      [{Telemetry.Metrics.Summary, [:foo], %{}, now, i, :request}]},
                     state
                   )

          state
        end)

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Summary, [:foo], %{}, :request} => [
                 {now, 1001}
               ]
             }

      assert_receive {:bypass_request, _conn, %{"timeSeries" => time_series}}
      assert length(time_series) == 1
      assert length(List.first(time_series)["points"]) == 1000
    end
  end
end
