defmodule API.Sockets.ErrorHandler do
  def handle_error(conn, :unauthenticated), do: Plug.Conn.send_resp(conn, 403, "Forbidden")
  def handle_error(conn, :invalid), do: Plug.Conn.send_resp(conn, 422, "Unprocessable Entity")
  def handle_error(conn, :rate_limit), do: Plug.Conn.send_resp(conn, 429, "Too many requests")
end
