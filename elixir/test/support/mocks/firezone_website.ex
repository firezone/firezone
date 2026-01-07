defmodule Portal.Mocks.FirezoneWebsite do
  @doc """
    elixir fix/component-versions % curl -iii https://www.firezone.dev/api/releases
    HTTP/2 200
    age: 178
    cache-control: max-age=10
    cdn-cache-control: max-age=60
    content-type: application/json
    date: Tue, 23 Dec 2025 06:03:29 GMT
    permissions-policy: browsing-topics=()
    server: Vercel
    strict-transport-security: max-age=63072000
    vary: rsc, next-router-state-tree, next-router-prefetch, next-router-segment-prefetch
    x-matched-path: /api/releases
    x-vercel-cache: HIT
    x-vercel-id: sfo1::iad1::j6p8c-1766469987502-dafdcbf7ae4c

    {"portal":"90a15941f258e768a031e5db3d8aed1127793ef2","apple":"1.5.10","android":"1.5.7","gui":"1.5.8","headless":"1.5.4","gateway":"1.4.18"}
  """
  def mock_versions_endpoint(bypass, versions \\ %{}) do
    versions_path = "/api/releases"
    test_pid = self()

    Bypass.stub(bypass, "GET", versions_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(versions))
    end)
  end
end
