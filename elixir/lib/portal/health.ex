defmodule Portal.Health do
  @moduledoc """
  Health check server that handles liveness and readiness probes.

  - `/healthz` - Liveness check, always returns 200 OK
  - `/readyz` - Readiness check, returns 200 when endpoints are ready,
                503 when draining or starting
  """
  use Plug.Router

  plug :match
  plug :dispatch

  def child_spec(_opts) do
    config = Portal.Config.fetch_env!(:portal, Portal.Health)
    port = Keyword.fetch!(config, :health_port)

    %{
      id: __MODULE__,
      start:
        {Bandit, :start_link,
         [
           [
             plug: __MODULE__,
             scheme: :http,
             port: port,
             thousand_island_options: [num_acceptors: 2]
           ]
         ]},
      type: :supervisor
    }
  end

  get "/healthz" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: :ok}))
  end

  get "/readyz" do
    conn = put_resp_content_type(conn, "application/json")
    draining_file_path = draining_file_path()

    cond do
      File.exists?(draining_file_path) ->
        send_resp(conn, 503, JSON.encode!(%{status: :draining}))

      not endpoints_ready?() ->
        send_resp(conn, 503, JSON.encode!(%{status: :starting}))

      true ->
        send_resp(conn, 200, JSON.encode!(%{status: :ready}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp draining_file_path do
    Portal.Config.fetch_env!(:portal, Portal.Health)[:draining_file_path]
  end

  defp endpoints_ready? do
    web_ready? = Process.whereis(PortalWeb.Endpoint) != nil
    api_ready? = Process.whereis(PortalAPI.Endpoint) != nil

    web_ready? and api_ready?
  end
end
