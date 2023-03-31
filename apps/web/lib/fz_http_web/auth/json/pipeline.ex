defmodule FzHttpWeb.Auth.JSON.Pipeline do
  @moduledoc """
  API Plug implementation module for Guardian.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :fz_http,
    error_handler: FzHttpWeb.Auth.JSON.ErrorHandler,
    module: FzHttpWeb.Auth.JSON.Authentication

  # 90 days
  @max_age 60 * 60 * 24 * 90

  plug Guardian.Plug.VerifyHeader, max_age: @max_age
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
end
