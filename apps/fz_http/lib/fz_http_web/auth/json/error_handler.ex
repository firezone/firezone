defmodule FzHttpWeb.Auth.JSON.ErrorHandler do
  @moduledoc """
  API Error Handler module implementation for Guardian.
  """
  use FzHttpWeb, :controller
  require Logger

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    Logger.warn("JSON.ErrorHandler.auth_error. Type: #{type}. Reason: #{reason}.")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, to_string(type))
  end
end
