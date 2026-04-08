defmodule Portal.Health do
  @moduledoc """
  Health check plug that handles readiness probes.

  - `/readyz` - Readiness check, returns 200 when endpoints are ready,
                503 when draining, database unavailable or starting

  Used as a plug in Phoenix endpoints (passes through non-health routes):

      plug Portal.Health
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/readyz", method: "GET"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_readyz_response()
    |> halt()
  end

  def call(conn, _opts), do: conn

  # sobelow_skip ["XSS.SendResp"]
  defp send_readyz_response(conn) do
    version = Application.spec(:portal, :vsn) |> to_string()

    cond do
      draining?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :draining, version: version}))

      not endpoints_ready?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :starting, version: version}))

      not repos_ready?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :database_unavailable, version: version}))

      true ->
        send_resp(conn, 200, JSON.encode!(%{status: :ready, version: version}))
    end
  end

  defp draining? do
    Portal.Config.fetch_env!(:portal, Portal.Health)[:draining_file_path]
    |> File.exists?()
  end

  @repos [
    Portal.Repo,
    Portal.Repo.Replica,
    Portal.Repo.Web,
    Portal.Repo.Api,
    Portal.Repo.Replica.Web,
    Portal.Repo.Replica.Api
  ]

  # sobelow_skip ["SQL.Query"]
  defp repos_ready? do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    repos = Keyword.get(config, :repos, @repos)
    query = Keyword.get(config, :repo_check_query, "SELECT 1")

    Enum.all?(repos, fn repo ->
      try do
        %{num_rows: 1} = Ecto.Adapters.SQL.query!(repo, query, [])
        true
      rescue
        _ -> false
      end
    end)
  end

  defp endpoints_ready? do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    web_endpoint = Keyword.fetch!(config, :web_endpoint)
    api_endpoint = Keyword.fetch!(config, :api_endpoint)
    ops_endpoint = Keyword.fetch!(config, :ops_endpoint)

    Process.whereis(web_endpoint) != nil and Process.whereis(api_endpoint) != nil and
      Process.whereis(ops_endpoint) != nil
  end
end
