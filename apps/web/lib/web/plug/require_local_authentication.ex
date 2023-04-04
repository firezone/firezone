defmodule Web.Plug.RequireLocalAuthentication do
  use Web, :controller

  def init(opts), do: opts

  def call(conn, _opts) do
    # XXX: This should be moved to Auth
    if Domain.Config.fetch_config!(:local_auth_enabled) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Local auth disabled")
      |> halt()
    end
  end
end
