defmodule Portal.Revocation.FailureTest do
  use ExUnit.Case, async: true

  alias Portal.Revocation.Failure

  defp endpoint(attrs \\ %{}) do
    struct(
      %Portal.RevocationEndpoint{errored_at: nil, crl_error: nil, ocsp_error: nil},
      attrs
    )
  end

  describe "error_fields/3" do
    test "an unreachable address stops the fetching at once" do
      now = DateTime.utc_now()

      fields = Failure.error_fields(endpoint(), {:blocked_address, "resolves to 127.0.0.1"}, now)

      assert fields[:is_disabled] == true
      assert fields[:disabled_reason] == Failure.disabled_reason()
      assert fields[:errored_at] == now
    end

    test "an address we cannot speak to stops the fetching at once" do
      fields = Failure.error_fields(endpoint(), :unsupported_url_scheme, DateTime.utc_now())

      assert fields[:is_disabled] == true
    end

    test "a timeout only starts the clock" do
      now = DateTime.utc_now()

      fields = Failure.error_fields(endpoint(), "timeout", now)

      assert fields[:errored_at] == now
      refute Keyword.has_key?(fields, :is_disabled)
    end

    test "a timeout keeps the clock it started rather than restarting it" do
      started = DateTime.add(DateTime.utc_now(), -3, :hour)

      fields =
        Failure.error_fields(endpoint(%{errored_at: started}), "timeout", DateTime.utc_now())

      assert fields[:errored_at] == started
      refute Keyword.has_key?(fields, :is_disabled)
    end

    test "a day of continuous failure stops the fetching" do
      started = DateTime.add(DateTime.utc_now(), -24, :hour)

      fields =
        Failure.error_fields(endpoint(%{errored_at: started}), "timeout", DateTime.utc_now())

      assert fields[:is_disabled] == true
      assert fields[:errored_at] == started
    end
  end

  describe "success_fields/2" do
    test "clears the streak when both mechanisms are healthy" do
      fields = Failure.success_fields(endpoint(), :crl)

      assert fields[:errored_at] == nil
    end

    test "a working responder does not reset the clock on a broken list" do
      assert Failure.success_fields(endpoint(%{crl_error: "timeout"}), :ocsp) == []
    end

    test "a working list does not reset the clock on a broken responder" do
      assert Failure.success_fields(endpoint(%{ocsp_error: "timeout"}), :crl) == []
    end

    test "nothing here ever re-enables an endpoint" do
      fields = Failure.success_fields(endpoint(%{is_disabled: true}), :crl)

      refute Keyword.has_key?(fields, :is_disabled)
      refute Keyword.has_key?(fields, :disabled_reason)
    end
  end
end
