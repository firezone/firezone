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
  def mock_versions_endpoint(versions \\ %{}) do
    test_pid = self()

    Req.Test.stub(Portal.ComponentVersions, fn conn ->
      send(test_pid, {:req_request, conn})

      case {conn.method, conn.request_path} do
        {"GET", "/api/releases"} ->
          Req.Test.json(conn, versions)

        {method, path} ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => "No mock expectation for #{method} #{path}"})
      end
    end)
  end
end
