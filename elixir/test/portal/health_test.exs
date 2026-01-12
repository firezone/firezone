defmodule Portal.HealthTest do
  use Portal.DataCase, async: true
  import Plug.Test

  defmodule FailingRepo do
    def query(_sql), do: {:error, %DBConnection.ConnectionError{message: "connection refused"}}
  end

  setup do
    draining_file_path =
      Path.join(
        System.tmp_dir!(),
        "firezone-draining-test-#{:erlang.unique_integer([:positive])}"
      )

    Portal.Config.put_env_override(:portal, Portal.Health, draining_file_path: draining_file_path)

    File.rm(draining_file_path)
    on_exit(fn -> File.rm(draining_file_path) end)

    {:ok, draining_file_path: draining_file_path}
  end

  describe "PortalWeb.Endpoint integration" do
    test "GET /healthz returns 200" do
      conn =
        Plug.Test.conn(:get, "/healthz")
        |> PortalWeb.Endpoint.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ok"}
    end

    test "GET /readyz returns 200 when ready" do
      conn =
        Plug.Test.conn(:get, "/readyz")
        |> PortalWeb.Endpoint.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ready"}
    end
  end

  describe "PortalAPI.Endpoint integration" do
    test "GET /healthz returns 200" do
      conn =
        Plug.Test.conn(:get, "/healthz")
        |> PortalAPI.Endpoint.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ok"}
    end

    test "GET /readyz returns 200 when ready" do
      conn =
        Plug.Test.conn(:get, "/readyz")
        |> PortalAPI.Endpoint.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ready"}
    end
  end

  describe "GET /healthz" do
    test "returns 200 with status ok" do
      conn =
        :get
        |> conn("/healthz")
        |> Portal.Health.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end

  describe "GET /readyz" do
    test "returns 200 with status ready when endpoints and database are up" do
      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"status" => "ready"}
    end

    test "returns 503 with status draining when draining file exists", %{
      draining_file_path: draining_file_path
    } do
      File.write!(draining_file_path, "")

      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 503
      assert JSON.decode!(conn.resp_body) == %{"status" => "draining"}
    end

    test "returns 503 with status starting when an endpoint is not ready", %{
      draining_file_path: draining_file_path
    } do
      Portal.Config.put_env_override(:portal, Portal.Health,
        draining_file_path: draining_file_path,
        api_endpoint: :nonexistent_endpoint
      )

      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 503
      assert JSON.decode!(conn.resp_body) == %{"status" => "starting"}
    end

    test "returns 503 with status database_unavailable when database query fails", %{
      draining_file_path: draining_file_path
    } do
      Portal.Config.put_env_override(:portal, Portal.Health,
        draining_file_path: draining_file_path,
        repo: Portal.HealthTest.FailingRepo
      )

      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 503
      assert JSON.decode!(conn.resp_body) == %{"status" => "database_unavailable"}
    end
  end

  describe "unknown routes" do
    test "passes through when used as plug" do
      conn =
        :get
        |> conn("/unknown")
        |> Portal.Health.call([])

      # Portal.Health passes through unknown routes (doesn't halt)
      refute conn.halted
      assert conn.status == nil
    end

    test "returns 404 when used as standalone server" do
      conn =
        :get
        |> conn("/unknown")
        |> Portal.Health.Server.call([])

      assert conn.status == 404
    end
  end
end
