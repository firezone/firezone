defmodule FzHttpWeb.Auth.WWW.Pipeline do
  @moduledoc """
  WWW Plug implementation module for Guardian.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :fz_http,
    error_handler: FzHttpWeb.Auth.WWW.ErrorHandler,
    module: FzHttpWeb.Auth.WWW.Authentication

  @claims %{"typ" => "access"}

  plug Guardian.Plug.VerifySession, claims: @claims, refresh_from_cookie: true
  plug Guardian.Plug.LoadResource, allow_blank: true
end
