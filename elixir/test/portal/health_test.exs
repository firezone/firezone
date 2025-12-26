defmodule Portal.HealthTest do
  use ExUnit.Case, async: true
  import Plug.Test

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

    test "returns 503 with status draining when draining file exists", %{
      draining_file_path: draining_file_path
    } do
      File.write!(draining_file_path, "")

      conn =
        :get
        |> conn("/readyz")
        |> Portal.Health.call([])

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"status" => "draining"}
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
