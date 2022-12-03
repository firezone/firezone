defmodule FzHttpWeb.Gateway.ErrorHandler do
  def handle_error(conn, {:unauthorized, _reason}) do
    Plug.Conn.send_resp(conn, 403, "Unauthorized Access")
    |> Plug.Conn.halt()
  end

  def handle_error(conn, _reason) do
    Plug.Conn.send_resp(conn, 500, "Internal Server Error")
    |> Plug.Conn.halt()
  end
end
