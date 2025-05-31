defmodule Web.HealthController do
  use Web, :controller

  def healthz(conn, _params) do
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
