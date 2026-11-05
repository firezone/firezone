defmodule PortalWeb.PublicEmailRateLimitTest do
  use ExUnit.Case, async: true

  alias PortalWeb.PublicEmailRateLimit

  describe "check/2" do
    test "limits each client IP separately" do
      Portal.Config.put_env_override(:portal, PublicEmailRateLimit, per_ip_per_hour: 2)
      ip = unique_ipv4()

      assert PublicEmailRateLimit.check(:public_email_test_per_ip, ip) == :ok
      assert PublicEmailRateLimit.check(:public_email_test_per_ip, ip) == :ok

      assert PublicEmailRateLimit.check(:public_email_test_per_ip, ip) ==
               {:error, :rate_limited}

      assert PublicEmailRateLimit.check(:public_email_test_per_ip, unique_ipv4()) == :ok
    end

    test "limits each scope separately" do
      Portal.Config.put_env_override(:portal, PublicEmailRateLimit, per_ip_per_hour: 1)
      ip = unique_ipv4()

      assert PublicEmailRateLimit.check(:public_email_test_scope_a, ip) == :ok

      assert PublicEmailRateLimit.check(:public_email_test_scope_a, ip) ==
               {:error, :rate_limited}

      assert PublicEmailRateLimit.check(:public_email_test_scope_b, ip) == :ok
    end

    test "IPv6 clients in the same /64 share one bucket" do
      Portal.Config.put_env_override(:portal, PublicEmailRateLimit, per_ip_per_hour: 1)
      {a, b, c, d} = {0x2001, 0xDB8, :rand.uniform(0xFFFF), :rand.uniform(0xFFFE)}

      assert PublicEmailRateLimit.check(:public_email_test_ipv6, {a, b, c, d, 0, 0, 0, 1}) ==
               :ok

      assert PublicEmailRateLimit.check(:public_email_test_ipv6, {a, b, c, d, 1, 2, 3, 4}) ==
               {:error, :rate_limited}

      assert PublicEmailRateLimit.check(:public_email_test_ipv6, {a, b, c, d + 1, 0, 0, 0, 1}) ==
               :ok
    end

    test "limits all clients together" do
      Portal.Config.put_env_override(:portal, PublicEmailRateLimit, global_per_hour: 2)

      assert PublicEmailRateLimit.check(:public_email_test_global, unique_ipv4()) == :ok
      assert PublicEmailRateLimit.check(:public_email_test_global, unique_ipv4()) == :ok

      assert PublicEmailRateLimit.check(:public_email_test_global, unique_ipv4()) ==
               {:error, :rate_limited}
    end

    test "reports each decision under the public_email limiter" do
      test_pid = self()
      handler_id = "test-public-email-rate-limit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:portal, :rate_limit, :decision],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:rate_limit_decision, self(), metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Portal.Config.put_env_override(:portal, PublicEmailRateLimit, per_ip_per_hour: 1)
      ip = unique_ipv4()

      assert PublicEmailRateLimit.check(:public_email_test_metric, ip) == :ok
      assert_receive {:rate_limit_decision, ^test_pid, %{limiter: :public_email, decision: :allow}}

      assert PublicEmailRateLimit.check(:public_email_test_metric, ip) == {:error, :rate_limited}
      assert_receive {:rate_limit_decision, ^test_pid, %{limiter: :public_email, decision: :deny}}
    end
  end

  defp unique_ipv4 do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end
end
