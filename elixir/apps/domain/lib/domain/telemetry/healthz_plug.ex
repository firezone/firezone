defmodule Domain.Telemetry.HealthzPlug do
  @moduledoc """
  A plug that returns a 200 OK response for health checks.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> respond_based_on_cluster_state()
    |> halt()
  end

  defp respond_based_on_cluster_state(conn) do
    if Domain.Cluster.healthy?() do
      send_resp(conn, 200, Jason.encode!(%{status: :ok}))
    else
      send_resp(conn, 503, Jason.encode!(%{status: :unavailable}))
    end
  end
end
