defmodule Portal.Revocation.FailureTest do
  use ExUnit.Case, async: true

  alias Portal.Revocation.Failure

  defp endpoint(attrs \\ %{}) do
    struct(%Portal.RevocationEndpoint{}, attrs)
  end

  describe "error_fields/4" do
    test "an unreachable address stops the fetching at once" do
      now = DateTime.utc_now()

      fields =
        Failure.error_fields(endpoint(), :crl, {:blocked_address, "resolves to 127.0.0.1"}, now)

      assert fields == [crl_errored_at: now, crl_is_disabled: true]
    end

    test "an address we cannot speak to stops the fetching at once" do
      fields = Failure.error_fields(endpoint(), :ocsp, :unsupported_url_scheme, DateTime.utc_now())

      assert fields[:ocsp_is_disabled] == true
    end

    test "a timeout only starts the clock" do
      now = DateTime.utc_now()

      fields = Failure.error_fields(endpoint(), :crl, "timeout", now)

      assert fields == [crl_errored_at: now]
    end

    test "a timeout keeps the clock it started rather than restarting it" do
      started = DateTime.add(DateTime.utc_now(), -3, :hour)

      fields =
        Failure.error_fields(
          endpoint(%{ocsp_errored_at: started}),
          :ocsp,
          "timeout",
          DateTime.utc_now()
        )

      assert fields == [ocsp_errored_at: started]
    end

    test "a day of continuous failure stops the fetching" do
      started = DateTime.add(DateTime.utc_now(), -24, :hour)

      fields =
        Failure.error_fields(
          endpoint(%{crl_errored_at: started}),
          :crl,
          "timeout",
          DateTime.utc_now()
        )

      assert fields == [crl_errored_at: started, crl_is_disabled: true]
    end

    test "the other mechanism's clock does not count toward this one" do
      started = DateTime.add(DateTime.utc_now(), -48, :hour)
      now = DateTime.utc_now()

      fields = Failure.error_fields(endpoint(%{crl_errored_at: started}), :ocsp, "timeout", now)

      assert fields == [ocsp_errored_at: now]
    end
  end

  describe "success_fields/1" do
    test "clears only the streak of the mechanism that succeeded" do
      assert Failure.success_fields(:crl) == [crl_errored_at: nil]
      assert Failure.success_fields(:ocsp) == [ocsp_errored_at: nil]
    end
  end
end
