defmodule Web.Auth.HTML.Pipeline do
  @moduledoc """
  HTML Plug implementation module for Guardian.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :web,
    error_handler: Web.Auth.HTML.ErrorHandler,
    module: Web.Auth.HTML.Authentication

  @claims %{"typ" => "access"}

  plug Guardian.Plug.VerifySession, claims: @claims, refresh_from_cookie: true
  plug Guardian.Plug.LoadResource, allow_blank: true
end
