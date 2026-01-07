defmodule Portal.Telemetry.Reporter.GoogleCloudMetricsTest do
  use Portal.DataCase, async: true
  import Portal.Telemetry.Reporter.GoogleCloudMetrics
  alias Portal.Mocks.GoogleCloudPlatform

  describe "handle_info/2 for :compressed_metrics" do
    setup do
      test_pid = self()

      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          GoogleCloudPlatform.mock_metrics_submit_endpoint_with_capture(test_pid)

      GoogleCloudPlatform.stub(expectations)

      :ok
    end

    test "aggregates and delivers Metrics.Counter metrics" do
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

      assert_receive {:metrics_request, _conn, body}

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

      assert_receive {:metrics_request, _conn, body}

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

      assert_receive {:metrics_request, _conn, body}

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

      assert_receive {:metrics_request, _conn, body}

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

      assert_receive {:metrics_request, _conn, body}

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

    test "flushes the metrics to Google Cloud when incoming metrics surpass buffer length" do
      now = DateTime.utc_now()
      tags = {%{type: "test"}, %{app: "myapp"}}

      # Send 200 metrics
      {_, _, _, {buffer_size, buffer}} =
        Enum.reduce(1..200, {[], "proj", tags, {0, %{}}}, fn i, state ->
          {:noreply, state} =
            handle_info(
              {:compressed_metrics,
               [{Telemetry.Metrics.Counter, [:foo, i], %{}, now, i, :request}]},
              state
            )

          state
        end)

      assert buffer_size == 200

      refute_receive {:metrics_request, _conn, _body}

      # Send the 201st metric, which should trigger the flush
      {:noreply, {_, _, _, {buffer_size, buffer}}} =
        handle_info(
          {:compressed_metrics,
           [{Telemetry.Metrics.Counter, [:foo, 200], %{}, now, 200, :request}]},
          {[], "proj", tags, {buffer_size, buffer}}
        )

      assert buffer == %{{Telemetry.Metrics.Counter, [:foo, 200], %{}, :request} => {now, now, 1}}
      assert buffer_size == 1
      assert_receive {:metrics_request, _conn, %{"timeSeries" => time_series}}
      assert length(time_series) == 200
    end

    test "handles large batches that exceed buffer capacity in single message" do
      now = DateTime.utc_now()
      tags = {%{type: "test"}, %{app: "myapp"}}

      # Start with 50 metrics in buffer
      {_, _, _, {buffer_size, buffer}} =
        Enum.reduce(1..50, {[], "proj", tags, {0, %{}}}, fn i, state ->
          {:noreply, state} =
            handle_info(
              {:compressed_metrics,
               [{Telemetry.Metrics.Counter, [:existing, i], %{}, now, i, :request}]},
              state
            )

          state
        end)

      assert buffer_size == 50

      # Now send a single large batch of 250 metrics (exceeds total capacity)
      large_batch =
        Enum.map(1..250, fn i ->
          {Telemetry.Metrics.Counter, [:batch, i], %{batch: "large"}, now, i, :request}
        end)

      {:noreply, {_, _, _, {final_buffer_size, final_buffer}}} =
        handle_info(
          {:compressed_metrics, large_batch},
          {[], "proj", tags, {buffer_size, buffer}}
        )

      # Buffer should never exceed capacity (200)
      assert final_buffer_size <= 200

      # Should receive flush request due to the large batch
      # First flush: The initial 50 metrics in buffer + 150 of the large batch
      assert_receive {:metrics_request, _conn, %{"timeSeries" => flush}}
      assert length(flush) == 200

      # Remaining metrics should still be in buffer. 50 + 250 - 200 = 100
      assert final_buffer_size == 100
      assert map_size(final_buffer) == 100

      # Verify all remaining metrics are from the large batch
      Enum.each(final_buffer, fn {{_schema, name, tags, _unit}, _measurements} ->
        assert [:batch, _] = name
        assert tags.batch == "large"
      end)
    end

    test "handles extremely large single batch that requires multiple flushes" do
      now = DateTime.utc_now()
      tags = {%{type: "test"}, %{app: "myapp"}}

      # Send a massive batch of 500 metrics
      massive_batch =
        Enum.map(1..500, fn i ->
          {Telemetry.Metrics.Counter, [:massive, i], %{batch: "huge"}, now, i, :request}
        end)

      {:noreply, {_, _, _, {final_buffer_size, final_buffer}}} =
        handle_info(
          {:compressed_metrics, massive_batch},
          {[], "proj", tags, {0, %{}}}
        )

      # Buffer should never exceed capacity
      assert final_buffer_size <= 200

      # Should receive multiple flushes as the large batch is processed
      # We expect at least 2 flushes (200 + 200, with 100 remaining)
      assert_receive {:metrics_request, _conn, %{"timeSeries" => flush1}}
      assert_receive {:metrics_request, _conn, %{"timeSeries" => flush2}}
      assert length(flush1) == 200
      assert length(flush2) == 200

      # Final buffer should contain the remaining 100 metrics
      assert final_buffer_size == 100
      assert map_size(final_buffer) == 100
    end
  end
end
