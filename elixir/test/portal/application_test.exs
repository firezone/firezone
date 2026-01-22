defmodule Portal.ApplicationTest do
  use ExUnit.Case, async: true

  describe "stop/1" do
    test "force flushes opentelemetry tracer provider without crashing" do
      # This is the same call made in Portal.Application.stop/1
      # It should return :ok whether or not the tracer provider is running
      assert :ok = :otel_tracer_provider.force_flush()
    end

    test "handles multiple opentelemetry force_flush calls gracefully" do
      # Calling force_flush multiple times should not crash
      _ = :otel_tracer_provider.force_flush()
      assert :ok = :otel_tracer_provider.force_flush()
    end

    test "removes logger handler without crashing" do
      # Use a unique handler ID to avoid conflicts with parallel tests
      handler_id = :"test_handler_#{:erlang.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler_id, Sentry.LoggerHandler, %{
          config: %{
            level: :warning,
            metadata: :all,
            capture_log_messages: true
          }
        })

      assert handler_id in :logger.get_handler_ids()

      # This is the same call made in Portal.Application.stop/1
      assert :ok = :logger.remove_handler(handler_id)

      refute handler_id in :logger.get_handler_ids()
    end

    test "does not crash when handler is already removed" do
      handler_id = :"test_handler_#{:erlang.unique_integer([:positive])}"

      # Handler doesn't exist - remove_handler returns error but doesn't crash
      # Portal.Application.stop/1 ignores this return value with `_ =`
      assert {:error, {:not_found, ^handler_id}} = :logger.remove_handler(handler_id)
    end
  end
end
