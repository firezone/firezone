defmodule FzHttpWeb.Auth.Gateway.Authentication do
  @moduledoc """
  Authentication for gateway channel
  """
  alias FzHttp.Gateways
  use Guardian, otp_app: :fz_http

  @impl Guardian
  def subject_for_token(gateway_id, _claims) do
    {:ok, to_string(gateway_id)}
  end

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    # Here we look for the gateway :D
    {:ok, Gateways.get_gateway!(id: id)}
  end
end
