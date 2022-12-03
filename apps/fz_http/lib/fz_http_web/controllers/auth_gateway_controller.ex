defmodule FzHttpWeb.AuthGatewayController do
  use FzHttpWeb, :controller
  require Logger

  def request(conn, params) do
    dbg(conn)
    dbg(params)

    case FzHttpWeb.Auth.Gateway.Authentication.encode_and_sign("gateway_id") do
      {:ok, token, claim} -> json(conn, %{token: token, claim: claim})
      {:err, err} -> json(conn, %{err: err})
    end
  end
end
