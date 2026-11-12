defmodule Portal.Req.BoundedTest do
  use ExUnit.Case, async: true

  alias Portal.Req.Bounded
  alias Portal.StreamingServer

  @mib 1_048_576

  describe "request/1" do
    test "returns a body within the limit" do
      test_pid = self()
      url = StreamingServer.start(&StreamingServer.send_chunks(&1, test_pid, 10, 4))

      assert {:ok, %Req.Response{status: 200, body: body}} = request(url: url, max_body_bytes: 100)
      assert body == String.duplicate("0", 40)
    end

    test "stops reading a body once it passes the limit" do
      test_pid = self()
      url = StreamingServer.start(&StreamingServer.send_chunks(&1, test_pid, @mib, 64))

      assert {:error, %Bounded.BodyTooLargeError{max_bytes: @mib}} =
               request(url: url, max_body_bytes: @mib, retry: false)

      assert_receive {:bytes_sent, sent}, 5_000
      assert sent < 16 * @mib
    end

    test "gives up when the whole call takes longer than the timeout" do
      url = StreamingServer.start(&StreamingServer.drip(&1, 50))
      started = System.monotonic_time(:millisecond)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               request(url: url, max_body_bytes: @mib, timeout: 300)

      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "counts retries against the timeout" do
      test_pid = self()

      url =
        StreamingServer.start(fn conn ->
          send(test_pid, :requested)
          Plug.Conn.send_resp(conn, 503, "")
        end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               request(url: url, max_body_bytes: @mib, timeout: 500, retry_log_level: false)

      assert_received :requested
    end

    test "follows at most three redirects by default" do
      test_pid = self()

      url =
        StreamingServer.start(fn conn ->
          send(test_pid, :requested)

          conn
          |> Plug.Conn.put_resp_header("location", "/again")
          |> Plug.Conn.send_resp(302, "")
        end)

      assert {:error, %Req.TooManyRedirectsError{max_redirects: 3}} =
               request(url: url, max_body_bytes: @mib, redirect_log_level: false)

      for _attempt <- 1..4, do: assert_received(:requested)
      refute_received :requested
    end

    test "returns a compressed body as it was sent" do
      compressed = :zlib.gzip(:binary.copy("0", 10 * @mib))

      url =
        StreamingServer.start(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, compressed)
        end)

      assert {:ok, %Req.Response{body: body}} =
               request(url: url, max_body_bytes: @mib, compressed: true)

      assert body == compressed
    end
  end

  defp request(options) do
    options
    |> Keyword.put(:allow_private_ips, true)
    |> Bounded.request()
  end
end
