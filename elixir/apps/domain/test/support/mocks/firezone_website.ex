defmodule Domain.Mocks.FirezoneWebsite do
  def mock_versions_endpoint(bypass, versions \\ %{}) do
    versions_path = "/api/releases"
    test_pid = self()

    Bypass.stub(bypass, "GET", versions_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(versions))
    end)
  end
end
