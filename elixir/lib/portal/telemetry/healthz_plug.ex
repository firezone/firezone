defmodule Portal.Telemetry.HealthzPlug do
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
    |> send_resp(200, JSON.encode!(%{status: :ok}))
    |> halt()
  end
end
