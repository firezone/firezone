defmodule Portal.OTLPTest do
  use ExUnit.Case, async: true

  alias Portal.OTLP

  describe "auth!/2" do
    test "uses the static headers when OTLP_AUTH is unset" do
      assert OTLP.auth!(nil, nil) == {:headers, []}
      assert OTLP.auth!("", " api-key = a%2Cb%3Dc , x-tenant=1") ==
               {:headers, [{"api-key", "a,b=c"}, {"x-tenant", "1"}]}
    end

    test "accepts azure-managed-identity" do
      assert OTLP.auth!("azure-managed-identity", "api-key=secret") == :azure_managed_identity
    end

    test "rejects any other OTLP_AUTH" do
      assert_raise ArgumentError, ~r/OTLP_AUTH/, fn -> OTLP.auth!("bearer", nil) end
    end

    test "rejects malformed headers without leaking their values" do
      for headers <- ["api-key", "=secret", "api-key=a,secret"] do
        error = assert_raise ArgumentError, fn -> OTLP.auth!(nil, headers) end
        refute error.message =~ "secret"
      end
    end
  end

  describe "validate_endpoint!/2" do
    test "accepts a full HTTPS URL" do
      endpoint = "https://otlp.example.com/v1/metrics"

      assert OTLP.validate_endpoint!(endpoint, "OTLP_METRICS_ENDPOINT") == endpoint
    end

    test "rejects anything else" do
      for endpoint <- [
            "http://otlp.example.com/v1/metrics",
            "https:///v1/metrics",
            "https://user:pass@otlp.example.com/v1/metrics",
            "https://otlp.example.com/v1/metrics#fragment",
            "otlp.example.com"
          ] do
        assert_raise ArgumentError, ~r/OTLP_METRICS_ENDPOINT/, fn ->
          OTLP.validate_endpoint!(endpoint, "OTLP_METRICS_ENDPOINT")
        end
      end
    end
  end
end
