defmodule PortalAPI.Plugs.ValidateUUIDParamsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias PortalAPI.Plugs.ValidateUUIDParams

  @valid_uuid "00000000-0000-0000-0000-000000000000"
  @opts ValidateUUIDParams.init([])

  defp build_conn(path_params) do
    conn(:get, "/test")
    |> put_private(:phoenix_endpoint, PortalAPI.Endpoint)
    |> put_private(:phoenix_format, "json")
    |> Map.put(:path_params, path_params)
  end

  describe "call/2" do
    test "passes through when no path params are present" do
      conn = build_conn(%{})
      result = ValidateUUIDParams.call(conn, @opts)
      refute result.halted
    end

    test "passes through when non-id params have any value" do
      conn = build_conn(%{"name" => "null", "type" => "not-a-uuid"})
      result = ValidateUUIDParams.call(conn, @opts)
      refute result.halted
    end

    test "passes through when id param is a valid UUID" do
      conn = build_conn(%{"id" => @valid_uuid})
      result = ValidateUUIDParams.call(conn, @opts)
      refute result.halted
    end

    test "passes through when all _id params are valid UUIDs" do
      conn = build_conn(%{"site_id" => @valid_uuid, "id" => @valid_uuid})
      result = ValidateUUIDParams.call(conn, @opts)
      refute result.halted
    end

    test "halts with 400 when id is the literal string null" do
      conn = build_conn(%{"id" => "null"})
      result = ValidateUUIDParams.call(conn, @opts)
      assert result.halted
      assert result.status == 400
    end

    test "halts with 400 when id is an arbitrary non-UUID string" do
      conn = build_conn(%{"id" => "not-a-uuid"})
      result = ValidateUUIDParams.call(conn, @opts)
      assert result.halted
      assert result.status == 400
    end

    test "halts with 400 when a _id param is invalid" do
      conn = build_conn(%{"site_id" => "null", "id" => @valid_uuid})
      result = ValidateUUIDParams.call(conn, @opts)
      assert result.halted
      assert result.status == 400
    end

    test "halts with 400 when id is an empty string" do
      conn = build_conn(%{"id" => ""})
      result = ValidateUUIDParams.call(conn, @opts)
      assert result.halted
      assert result.status == 400
    end
  end
end
