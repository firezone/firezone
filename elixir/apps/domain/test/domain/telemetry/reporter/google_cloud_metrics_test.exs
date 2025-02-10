defmodule Domain.Telemetry.Reporter.GoogleCloudMetricsTest do
  use Domain.DataCase, async: true
  import Domain.Telemetry.Reporter.GoogleCloudMetrics
  alias Domain.Mocks.GoogleCloudPlatform
  alias Domain.Telemetry.Reporter.Log

  describe "handle_info/2 for :flush" do
    test "updates reporter_logs table with last_flushed_at" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      reporter_module = "Elixir.Domain.Telemetry.Reporter.GoogleCloudMetrics"

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, one_minute_ago, 1,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, :request} =>
                 {one_minute_ago, one_minute_ago, 1}
             }

      # Flush
      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert %Log{last_flushed_at: last_flushed_at} =
               Log.Query.all()
               |> Log.Query.by_reporter_module(reporter_module)
               |> Repo.one()

      assert DateTime.diff(last_flushed_at, now, :second) < 1

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, one_minute_ago, 1,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, :request} =>
                 {one_minute_ago, one_minute_ago, 1}
             }

      # Flush again; assert buffer didn't change
      assert {:noreply,
              {_, _, _,
               {1,
                %{
                  {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, :request} =>
                    {one_minute_ago, one_minute_ago, 1}
                }}}} = handle_info(:flush, state)

      # Assert last_flushed_at is not updated
      assert %Log{last_flushed_at: last_flushed_at2} =
               Log.Query.all()
               |> Log.Query.by_reporter_module(reporter_module)
               |> Repo.one()

      assert last_flushed_at == last_flushed_at2

      # Reset last_updated_at, flush, and assert last_flushed_at is updated
      Log.Query.all()
      |> Log.Query.by_reporter_module(reporter_module)
      |> Repo.one()
      |> Log.Changeset.changeset(%{last_flushed_at: one_minute_ago})
      |> Repo.update()

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert %Log{last_flushed_at: last_flushed_at3} =
               Log.Query.all()
               |> Log.Query.by_reporter_module(reporter_module)
               |> Repo.one()

      assert DateTime.diff(last_flushed_at3, now, :second) < 1
    end
  end

  describe "handle_info/2 for :compressed_metrics" do
    test "aggregates and delivers Metrics.Counter metrics" do
      Bypass.open()
      |> GoogleCloudPlatform.mock_instance_metadata_token_endpoint()
      |> GoogleCloudPlatform.mock_metrics_submit_endpoint()

      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)
      two_minutes_ago = DateTime.add(now, -2, :minute)

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Counter, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
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
                     "labels" => %{"foo" => "bar", "app" => "myapp"}
                   },
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "INT64",
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

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, two_minutes_ago,
                     5.5, :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Distribution, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, {1, 5.5, 5.5, 5.5, 0, %{0 => 0, 8 => 1}}}
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
                 {two_minutes_ago, one_minute_ago,
                  {2, 16.8, 5.5, 11.3, 8.410000000000002, %{0 => 0, 8 => 1, 16 => 1}}}
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
                 {two_minutes_ago, one_minute_ago,
                  {3, 15.8, -1, 11.3, 47.681111111111115, %{0 => 1, 8 => 1, 16 => 1}}}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/distribution",
                     "labels" => %{"foo" => "bar", "app" => "myapp"}
                   },
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DISTRIBUTION",
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
                           "sumOfSquaredDeviation" => 47.681111111111115,
                           "bucketCounts" => [1, 1, 1, 0],
                           "bucketOptions" => %{
                             "exponentialBuckets" => %{
                               "growthFactor" => 2,
                               "numFiniteBuckets" => 3,
                               "scale" => 1
                             }
                           }
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

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Sum, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
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
                     "labels" => %{"foo" => "bar", "app" => "myapp"}
                   },
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DOUBLE",
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

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, two_minutes_ago, 5.5,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
               )

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, two_minutes_ago, {1, 5.5, 5.5, 5.5, 0, %{0 => 0, 8 => 1}}}
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

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Summary, [:foo], %{"foo" => "bar"}, :request} =>
                 {two_minutes_ago, one_minute_ago,
                  {2, 16.8, 5.5, 11.3, 8.410000000000002, %{0 => 0, 8 => 1, 16 => 1}}}
             }

      assert {:noreply, {_, _, _, {0, %{}}}} = handle_info(:flush, state)

      assert_receive {:bypass_request, _conn, body}

      assert body == %{
               "timeSeries" => [
                 %{
                   "metric" => %{
                     "type" => "custom.googleapis.com/elixir/foo/summary",
                     "labels" => %{"foo" => "bar", "app" => "myapp"}
                   },
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "metricKind" => "CUMULATIVE",
                   "valueType" => "DISTRIBUTION",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago),
                         "startTime" => DateTime.to_iso8601(two_minutes_ago)
                       },
                       "value" => %{
                         "distributionValue" => %{
                           "count" => 2,
                           "mean" => 8.4,
                           "sumOfSquaredDeviation" => 8.410000000000002,
                           "bucketCounts" => [0, 1, 1, 0],
                           "bucketOptions" => %{
                             "exponentialBuckets" => %{
                               "growthFactor" => 2,
                               "numFiniteBuckets" => 3,
                               "scale" => 1
                             }
                           }
                         }
                       }
                     }
                   ]
                 },
                 %{
                   "metric" => %{
                     "labels" => %{"app" => "myapp", "foo" => "bar"},
                     "type" => "custom.googleapis.com/elixir/foo/min_val"
                   },
                   "metricKind" => "GAUGE",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago)
                       },
                       "value" => %{"doubleValue" => 5.5}
                     }
                   ],
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "valueType" => "DOUBLE"
                 },
                 %{
                   "metric" => %{
                     "labels" => %{"app" => "myapp", "foo" => "bar"},
                     "type" => "custom.googleapis.com/elixir/foo/max_val"
                   },
                   "metricKind" => "GAUGE",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago)
                       },
                       "value" => %{"doubleValue" => 11.3}
                     }
                   ],
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "valueType" => "DOUBLE"
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

      tags = {%{type: "test"}, %{app: "myapp"}}

      assert {:noreply, {[], "proj", ^tags, {buffer_size, buffer}} = state} =
               handle_info(
                 {:compressed_metrics,
                  [
                    {Telemetry.Metrics.LastValue, [:foo], %{"foo" => "bar"}, two_minutes_ago, 1,
                     :request}
                  ]},
                 {[], "proj", tags, {0, %{}}}
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
                     "labels" => %{"foo" => "bar", "app" => "myapp"}
                   },
                   "resource" => %{"type" => "test"},
                   "unit" => "request",
                   "metricKind" => "GAUGE",
                   "valueType" => "DOUBLE",
                   "points" => [
                     %{
                       "interval" => %{
                         "endTime" => DateTime.to_iso8601(one_minute_ago)
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
      tags = {%{type: "test"}, %{app: "myapp"}}

      {_, _, _, {buffer_size, buffer}} =
        Enum.reduce(1..201, {[], "proj", tags, {0, %{}}}, fn i, state ->
          {:noreply, state} =
            handle_info(
              {:compressed_metrics,
               [{Telemetry.Metrics.Counter, [:foo, i], %{}, now, i, :request}]},
              state
            )

          state
        end)

      assert buffer_size == 1

      assert buffer == %{
               {Telemetry.Metrics.Counter, [:foo, 201], %{}, :request} => {now, now, 1}
             }

      assert_receive {:bypass_request, _conn, %{"timeSeries" => time_series}}
      assert length(time_series) == 200
    end
  end
end
