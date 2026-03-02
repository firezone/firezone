defmodule Portal.Telemetry.SentryTest do
  use ExUnit.Case, async: true

  describe "before_send/1" do
    test "drops libcluster timeout warning messages" do
      event = %{
        message: %{
          formatted: "Node ~p not responding **~n** Removing (timedout) connection"
        }
      }

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "drops libcluster unable to connect warning messages" do
      event = %{
        message: %{
          formatted: "[libcluster:default] unable to connect to :foo@127.0.0.1"
        }
      }

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "drops libcluster global partition overlap warning messages" do
      event = %{
        message: %{
          formatted:
            "'global' at node 'worker@127.0.0.1' disconnected node 'worker@127.0.0.2' in order to prevent overlapping partitions"
        }
      }

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "passes through unrelated messages" do
      event = %{message: %{formatted: "some other warning"}}

      assert Portal.Telemetry.Sentry.before_send(event) == event
    end

    test "does not drop partial global partition text" do
      event = %{
        message: %{
          formatted: "'global' at node 'worker@127.0.0.1' saw partition overlap risk"
        }
      }

      assert Portal.Telemetry.Sentry.before_send(event) == event
    end

    test "drops events with skip_sentry set on original exception" do
      event = %{original_exception: %{skip_sentry: true}}

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "drops Ecto.NoResultsError exceptions" do
      event = %{original_exception: %Ecto.NoResultsError{}}

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "drops invalid CSRF token exceptions" do
      event = %{
        original_exception: Plug.CSRFProtection.InvalidCSRFTokenError.exception([])
      }

      assert Portal.Telemetry.Sentry.before_send(event) == nil
    end

    test "passes through non-message events without ignored exceptions" do
      event = %{foo: :bar}

      assert Portal.Telemetry.Sentry.before_send(event) == event
    end
  end
end
