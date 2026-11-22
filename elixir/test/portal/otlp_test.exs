defmodule Portal.OTLPTest do
  use ExUnit.Case, async: true

  @endpoint "https://ingest.test/v1/metrics"
  @req_opts [plug: {Req.Test, Portal.OTLP}, retry_delay: 0, max_retries: 4]

  test "retries a failed DNS lookup" do
    Req.Test.expect(Portal.OTLP, &Req.Test.transport_error(&1, :nxdomain))
    Req.Test.expect(Portal.OTLP, &Plug.Conn.send_resp(&1, 200, ""))

    assert Portal.OTLP.post(@endpoint, "", {:headers, []}, @req_opts) == :ok
  end

  test "retries a retryable status" do
    Req.Test.expect(Portal.OTLP, &Plug.Conn.send_resp(&1, 503, ""))
    Req.Test.expect(Portal.OTLP, &Plug.Conn.send_resp(&1, 200, ""))

    assert Portal.OTLP.post(@endpoint, "", {:headers, []}, @req_opts) == :ok
  end

  test "gives up after the last retry" do
    Req.Test.expect(Portal.OTLP, 5, &Req.Test.transport_error(&1, :nxdomain))

    assert Portal.OTLP.post(@endpoint, "", {:headers, []}, @req_opts) == :failed_retryable
  end

  test "does not retry a client error" do
    Req.Test.expect(Portal.OTLP, &Plug.Conn.send_resp(&1, 400, ""))

    assert Portal.OTLP.post(@endpoint, "", {:headers, []}, @req_opts) == :failed_not_retryable
  end
end
