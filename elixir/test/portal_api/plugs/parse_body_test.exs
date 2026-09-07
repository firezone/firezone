defmodule PortalAPI.Plugs.ParseBodyTest do
  use ExUnit.Case, async: true

  alias PortalAPI.Plugs.{MCPParseBody, ParseBody}

  # Mark the conn returned by the body reader so rescuing with the pre-read conn
  # fails these tests even with Plug.Test's more permissive adapter.
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} -> {status, body, Plug.Conn.assign(conn, :body_read, true)}
      error -> error
    end
  end

  defp parse(plug, body, opts \\ []) do
    opts =
      Keyword.merge(
        [
          parsers: [Portal.Parsers.JSON],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library(),
          body_reader: {__MODULE__, :read_body, []}
        ],
        opts
      )

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    plug.call(conn, plug.init(opts))
  end

  test "REST malformed JSON uses the conn returned by the body reader" do
    for body <- [<<0>>, <<255>>, "{", "[1,"] do
      conn = parse(ParseBody, body)

      assert conn.status == 400
      assert conn.halted
      assert conn.assigns.body_read

      assert Plug.Conn.get_resp_header(conn, "content-type") ==
               ["application/problem+json; charset=utf-8"]

      assert JSON.decode!(conn.resp_body)["detail"] == "The request body could not be parsed."
    end
  end

  test "MCP malformed JSON retains its JSON-RPC response and the updated conn" do
    conn = parse(MCPParseBody, <<0>>)

    assert conn.status == 400
    assert conn.halted
    assert conn.assigns.body_read

    assert JSON.decode!(conn.resp_body) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32700, "message" => "Parse error"}
           }
  end

  test "valid JSON keeps Plug's map, scalar, array, and empty-body semantics" do
    for plug <- [ParseBody, MCPParseBody],
        {body, expected} <- [
          {~s({"name":"test"}), %{"name" => "test"}},
          {"[1,2]", %{"_json" => [1, 2]}},
          {"null", %{"_json" => nil}},
          {"1", %{"_json" => 1}},
          {"", %{}}
        ] do
      conn = parse(plug, body)
      refute conn.halted
      assert conn.assigns.body_read
      assert conn.body_params == expected
    end
  end

  test "supports MFA decoders and nesting JSON maps" do
    conn =
      parse(ParseBody, ~s({"name":"test"}),
        json_decoder: {JSON, :decode!, []},
        nest_all_json: true
      )

    assert conn.body_params == %{"_json" => %{"name" => "test"}}
  end

  test "oversized bodies retain the updated conn and their 413 exception" do
    error = assert_raise Plug.Conn.WrapperError, fn -> parse(ParseBody, "[1,2,3]", length: 2) end
    assert %Plug.Parsers.RequestTooLargeError{} = error.reason
    assert error.conn.assigns.body_read
    assert Plug.Exception.status(error.reason) == 413
  end
end
