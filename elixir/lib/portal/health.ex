defmodule Portal.Health do
  @moduledoc """
  Health check plug that handles readiness probes.

  - `/readyz` - Readiness check, returns 200 when endpoints are ready,
                503 when draining, database unavailable or starting.
                The body's `ApplicationHealthState` is `Healthy` or `Unhealthy`
                to match, for the Azure Application Health extension.

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

  defp send_readyz_response(conn) do
    cond do
      draining?() -> send_readyz(conn, 503, :draining)
      not endpoints_ready?() -> send_readyz(conn, 503, :starting)
      not repos_ready?() -> send_readyz(conn, 503, :database_unavailable)
      true -> send_readyz(conn, 200, :ready)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp send_readyz(conn, status_code, status) do
    body = %{
      status: status,
      version: Application.spec(:portal, :vsn) |> to_string(),
      ApplicationHealthState: if(status_code == 200, do: "Healthy", else: "Unhealthy")
    }

    send_resp(conn, status_code, JSON.encode!(body))
  end

  defp draining? do
    Portal.Config.fetch_env!(:portal, Portal.Health)[:draining_file_path]
    |> File.exists?()
  end

  # Deliberately excludes the poller pools: their cycle-long checkouts would
  # make the readiness query queue up and fail
  @repos [
    Portal.Repo,
    Portal.Repo.Web,
    Portal.Repo.Api,
    Portal.Repo.Job
  ]

  defp repos_ready? do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    repos = Keyword.get(config, :repos, @repos)
    query = Keyword.get(config, :repo_check_query, "SELECT 1")

    repos
    |> Task.async_stream(&repo_ready?(&1, query),
      max_concurrency: max(length(repos), 1),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.all?(fn
      {:ok, true} -> true
      _ -> false
    end)
  end

  # sobelow_skip ["SQL.Query"]
  defp repo_ready?(repo, query) do
    match?({:ok, %{num_rows: 1}}, Ecto.Adapters.SQL.query(repo, query, []))
  end

  defp endpoints_ready? do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    web_endpoint = Keyword.fetch!(config, :web_endpoint)
    api_endpoint = Keyword.fetch!(config, :api_endpoint)
    ops_endpoint = Keyword.fetch!(config, :ops_endpoint)

    # The ops endpoint only exists in builds that include the private ops dashboard.
    Process.whereis(web_endpoint) != nil and Process.whereis(api_endpoint) != nil and
      (Process.whereis(ops_endpoint) != nil or not Code.ensure_loaded?(ops_endpoint))
  end
end
