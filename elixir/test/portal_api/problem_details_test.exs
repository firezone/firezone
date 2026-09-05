defmodule PortalAPI.ProblemDetailsTest do
  use ExUnit.Case, async: true

  alias PortalAPI.ProblemDetails

  describe "rate_limited/2" do
    test "exposes the rounded-up delay to consumers without response headers" do
      conn = ProblemDetails.rate_limited(Plug.Test.conn(:post, "/mcp"), 1501)

      assert conn.status == 429
      assert conn.halted
      assert content_type(conn) =~ "application/problem+json"
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["2"]
      assert json_body(conn)["retry_after_seconds"] == 2
      assert json_body(conn)["detail"] == "Rate limit exceeded. Retry after 2 seconds."
    end

    test "uses a minimum delay of one second" do
      conn = ProblemDetails.rate_limited(Plug.Test.conn(:post, "/mcp"), 0)

      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
      assert json_body(conn)["retry_after_seconds"] == 1
    end
  end

  describe "send/4" do
    test "builds an RFC 9457 body without a code member" do
      conn = ProblemDetails.send(Plug.Test.conn(:get, "/"), 404, "Not here")

      assert conn.status == 404
      assert conn.halted
      assert content_type(conn) =~ "application/problem+json"

      assert json_body(conn) == %{
               "type" => "about:blank",
               "title" => "Not Found",
               "status" => 404,
               "detail" => "Not here"
             }
    end

    test "merges extension members into the body" do
      conn =
        ProblemDetails.send(Plug.Test.conn(:get, "/"), 422, "Invalid", %{
          validation_errors: %{"name" => ["can't be blank"]}
        })

      assert json_body(conn)["validation_errors"] == %{"name" => ["can't be blank"]}
    end
  end

  describe "send_with_code/5" do
    test "emits the code as a top-level string alongside the standard members" do
      conn =
        ProblemDetails.send_with_code(Plug.Test.conn(:get, "/"), 403, :device_untrusted, "Nope")

      assert conn.status == 403
      assert conn.halted
      assert content_type(conn) =~ "application/problem+json"

      assert json_body(conn) == %{
               "type" => "about:blank",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "Nope",
               "code" => "device_untrusted"
             }
    end

    test "keeps extension members alongside the code" do
      conn =
        ProblemDetails.send_with_code(
          Plug.Test.conn(:get, "/"),
          400,
          :invalid_connect_params,
          "Bad",
          %{validation_errors: %{"name" => ["can't be blank"]}}
        )

      body = json_body(conn)

      assert body["code"] == "invalid_connect_params"
      assert body["validation_errors"] == %{"name" => ["can't be blank"]}
    end
  end

  defp json_body(conn), do: JSON.decode!(conn.resp_body)

  defp content_type(conn) do
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    content_type
  end
end
