defmodule Web.SignOutController do
  use Web, :controller
  alias Web.Session.Redirector

  def sign_out(conn, params) do
    Redirector.signed_out(conn, params["account_id_or_slug"])
  end
end
