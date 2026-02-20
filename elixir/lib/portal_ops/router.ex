defmodule PortalOps.Router do
  use Phoenix.Router
  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router

  @csp "default-src 'self'; " <>
         "script-src 'self' 'unsafe-inline'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; " <>
         "font-src 'self'; " <>
         "connect-src 'self' ws: wss:; " <>
         "frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  scope "/" do
    pipe_through :browser
    oban_dashboard "/oban"
    live_dashboard "/dashboard", metrics: Portal.Telemetry
  end
end
