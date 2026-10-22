defmodule Portal.Parsers.URLENCODEDTest do
  use ExUnit.Case, async: true

  # Mark the conn returned by the body reader so a wrapper carrying the
  # pre-read conn fails these tests even with Plug.Test's permissive adapter.
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} -> {status, body, Plug.Conn.assign(conn, :body_read, true)}
      error -> error
    end
  end

  defp parse(body, opts \\ []) do
    opts =
      Keyword.merge(
        [
          parsers: [Portal.Parsers.URLENCODED],
          pass: ["*/*"],
          body_reader: {__MODULE__, :read_body, []}
        ],
        opts
      )

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Plug.Parsers.call(Plug.Parsers.init(opts))
  end

  test "decodes a valid body" do
    conn = parse("a=1&b[]=2")
    assert conn.assigns.body_read
    assert conn.body_params == %{"a" => "1", "b" => ["2"]}
  end

  test "an invalid UTF-8 body carries the updated conn and a 400 exception" do
    error = assert_raise Plug.Conn.WrapperError, fn -> parse("a=%FF") end
    assert %Plug.Parsers.BadEncodingError{} = error.reason
    assert error.conn.assigns.body_read
    assert Plug.Exception.status(error.reason) == 400
  end

  test "an oversized body carries the updated conn and a 413 exception" do
    error = assert_raise Plug.Conn.WrapperError, fn -> parse("a=1&b=2", length: 2) end
    assert %Plug.Parsers.RequestTooLargeError{} = error.reason
    assert error.conn.assigns.body_read
    assert Plug.Exception.status(error.reason) == 413
  end
end
