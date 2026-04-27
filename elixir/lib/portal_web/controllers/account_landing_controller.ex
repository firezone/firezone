defmodule PortalWeb.AccountLandingController do
  use PortalWeb, :controller

  @spec redirect_to_sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug}) do
    path =
      if conn.query_string != "" do
        ~p"/#{account_id_or_slug}/sign_in" <> "?" <> conn.query_string
      else
        ~p"/#{account_id_or_slug}/sign_in"
      end

    redirect(conn, to: path)
  end
end
