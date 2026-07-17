defmodule PortalWeb.SentinelConsentController do
  @moduledoc """
  Landing for the Microsoft Sentinel admin consent redirect. Entra requires a
  registered reply address, and the consenting admin is often not a signed-in
  portal user, so the outcome renders as a standalone page that closes itself
  rather than a redirect into the authenticated app.
  """
  use PortalWeb, :controller

  plug :put_root_layout, html: {PortalWeb.Layouts, :verification}
  plug :put_layout, html: false

  def callback(conn, %{"admin_consent" => "True"}) do
    render(conn, :granted)
  end

  def callback(conn, %{"error" => error} = params) do
    render(conn, :declined, error: params["error_description"] || error)
  end

  def callback(conn, _params) do
    render(conn, :declined, error: "The consent response was missing or invalid.")
  end
end
