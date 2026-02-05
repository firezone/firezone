defmodule Portal.Health do
  @moduledoc """
  Health check plug that handles liveness and readiness probes.

  - `/healthz` - Liveness check, always returns 200 OK
  - `/readyz` - Readiness check, returns 200 when endpoints are ready,
                503 when draining or starting

  Can be used in two ways:

  1. As a plug in Phoenix endpoints (passes through non-health routes):

      plug Portal.Health

  2. As a standalone server on a dedicated port (returns 404 for unknown routes):

      children = [Portal.Health]
  """
  import Plug.Conn

  @behaviour Plug

  def child_spec(_opts) do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    port = Keyword.fetch!(config, :health_port)

    %{
      id: __MODULE__,
      start:
        {Bandit, :start_link,
         [
           [
             plug: Portal.Health.Server,
             scheme: :http,
             port: port,
             thousand_island_options: [num_acceptors: 2]
           ]
         ]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/healthz", method: "GET"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: :ok}))
    |> halt()
  end

  def call(%Plug.Conn{request_path: "/readyz", method: "GET"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_readyz_response()
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp send_readyz_response(conn) do
    version = Application.spec(:portal, :vsn) |> to_string()

    cond do
      draining?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :draining, version: version}))

      not endpoints_ready?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :starting, version: version}))

      true ->
        send_resp(conn, 200, JSON.encode!(%{status: :ready, version: version}))
    end
  end

  defp draining? do
    Portal.Config.fetch_env!(:portal, Portal.Health)[:draining_file_path]
    |> File.exists?()
  end

  defp endpoints_ready? do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    web_endpoint = Keyword.fetch!(config, :web_endpoint)
    api_endpoint = Keyword.fetch!(config, :api_endpoint)

    Process.whereis(web_endpoint) != nil and Process.whereis(api_endpoint) != nil
  end
end

defmodule Portal.Health.Server do
  @moduledoc false
  # Wrapper for standalone health server that returns 404 for unknown routes
  use Plug.Builder

  plug Portal.Health
  plug :not_found

  defp not_found(conn, _opts) do
    Plug.Conn.send_resp(conn, 404, "Not found")
  end
end
