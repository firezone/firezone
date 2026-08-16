defmodule PortalWeb.AccountLandingController do
  use PortalWeb, :controller

  @spec redirect_to_sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    redirect(conn, to: ~p"/#{account_id_or_slug}/sign_in?#{sign_in_params}")
  end
end
