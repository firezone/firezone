defmodule FzHttpWeb.AuthGatewayController do
  alias FzHttp.Gateways
  use FzHttpWeb, :controller
  require Logger

  # XXX: Secret is being logged! 😱
  def request(conn, %{"secret" => secret}) do
    case Base.decode64(secret) do
      {:ok, secret} -> validate_and_register(conn, secret)
      :error -> conn |> put_status(406) |> json(%{error: "Invalid token encoding"})
    end
  end

  defp validate_and_register(conn, secret) do
    if check_token(secret) do
      {:ok, gateway} = Gateways.find_or_create_default_gateway()

      authenticate(conn, gateway)
    else
      conn
      |> put_status(401)
      |> json(%{error: "Invalid token"})
    end
  end

  defp authenticate(conn, gateway) do
    case FzHttpWeb.Auth.Gateway.Authentication.encode_and_sign(gateway.id) do
      {:ok, token, claim} -> json(conn, %{token: token, claim: claim})
      {:error, err} -> conn |> put_status(500) |> json(%{error: err})
    end
  end

  defp check_token(secret) do
    :crypto.hash_equals(
      secret,
      Base.decode64!(Application.fetch_env!(:fz_http, :gateway_registration_token))
    )
  end
end
