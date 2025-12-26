defmodule Portal.HealthTest do
  use ExUnit.Case, async: true
  import Plug.Test

  describe "GET /healthz" do
    test "returns 200 with status ok" do
      conn =
        :get
        |> conn("/healthz")
        |> Portal.Health.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end

  describe "GET /readyz" do
    test "returns 200 with status ready when endpoints are up" do
      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ready"}
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn =
        :get
        |> conn("/unknown")
        |> Portal.Health.call([])

      assert conn.status == 404
    end
  end
end
