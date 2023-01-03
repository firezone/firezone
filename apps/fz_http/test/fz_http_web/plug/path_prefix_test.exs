defmodule FzHttpWeb.Plug.PathPrefixTest do
  use FzHttpWeb.ConnCase, async: true
  import Plug.Test
  import FzHttpWeb.Plug.PathPrefix

  describe "init/1" do
    test "returns the opts" do
      assert init(:foo) == :foo
    end
  end

  describe "call/2" do
    test "does nothing when path prefix is not configured" do
      FzHttp.Config.maybe_put_env_override(:path_prefix, nil)
      conn = conn(:get, "/")
      assert call(conn, []) == conn

      FzHttp.Config.maybe_put_env_override(:path_prefix, "/")
      conn = conn(:get, "/foo")
      assert call(conn, []) == conn
    end

    test "removes prefix from conn.request_path" do
      FzHttp.Config.maybe_put_env_override(:path_prefix, "/vpn/")
      conn = conn(:get, "/vpn/foo")
      assert returned_conn = call(conn, [])
      assert returned_conn.request_path == "/foo"
      assert returned_conn.request_path != conn.request_path
      assert get_resp_header(returned_conn, "location") == []
    end

    test "removes prefix from conn.path_info" do
      FzHttp.Config.maybe_put_env_override(:path_prefix, "/vpn/")
      conn = conn(:get, "/vpn/foo")
      assert returned_conn = call(conn, [])
      assert returned_conn.path_info == ["foo"]
      assert returned_conn.path_info != conn.path_info
      assert get_resp_header(returned_conn, "location") == []
    end

    test "redirects users from not prefixed path" do
      FzHttp.Config.maybe_put_env_override(:path_prefix, "/vpn/")

      conn = conn(:get, "/foo")
      assert returned_conn = call(conn, [])
      assert returned_conn.path_info == ["foo"]
      assert returned_conn.request_path == "/foo"
      assert get_resp_header(returned_conn, "location") == ["/vpn/foo"]

      conn = conn(:get, "/dist/font.woff2")
      assert returned_conn = call(conn, [])
      assert returned_conn.path_info == ["dist", "font.woff2"]
      assert returned_conn.request_path == "/dist/font.woff2"
      assert get_resp_header(returned_conn, "location") == ["/vpn/dist/font.woff2"]
    end
  end
end
