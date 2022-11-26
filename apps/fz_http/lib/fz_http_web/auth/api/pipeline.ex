defmodule FzHttpWeb.Auth.API.Pipeline do
  @moduledoc """
  API Plug implementation module for Guardian.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :fz_http,
    error_handler: FzHttpWeb.Auth.API.ErrorHandler,
    module: FzHttpWeb.Auth.API.Authentication

  # 90 days
  @max_age 60 * 60 * 24 * 90
  @claims %{"typ" => "api"}

  plug Guardian.Plug.VerifyHeader, claims: @claims, max_age: @max_age
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
end
