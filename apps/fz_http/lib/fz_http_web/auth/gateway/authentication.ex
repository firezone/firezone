defmodule FzHttpWeb.Auth.Gateway.Authentication do
  @moduledoc """
  Authentication for gateway channel
  """
  use Guardian, otp_app: :fz_http

  @impl Guardian
  def subject_for_token(_resource, _claims) do
    # Here we use the gateway uuid?
    {:ok, to_string("thisisagatewayid")}
  end

  @impl Guardian
  def resource_from_claims(_resource) do
    # Here we look for the gateway :D
    {:ok, "gateway"}
  end
end
