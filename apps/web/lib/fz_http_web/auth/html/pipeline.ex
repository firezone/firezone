defmodule FzHttpWeb.Auth.HTML.Pipeline do
  @moduledoc """
  HTML Plug implementation module for Guardian.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :fz_http,
    error_handler: FzHttpWeb.Auth.HTML.ErrorHandler,
    module: FzHttpWeb.Auth.HTML.Authentication

  @claims %{"typ" => "access"}

  plug Guardian.Plug.VerifySession, claims: @claims, refresh_from_cookie: true
  plug Guardian.Plug.LoadResource, allow_blank: true
end
