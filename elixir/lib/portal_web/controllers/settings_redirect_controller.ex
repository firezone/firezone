defmodule PortalWeb.SettingsRedirectController do
  use PortalWeb, :controller

  def dns(conn, %{"account_id_or_slug" => account}) do
    redirect(conn, to: ~p"/#{account}/settings/connectivity")
  end

  def dns_edit(conn, %{"account_id_or_slug" => account}) do
    redirect(conn, to: ~p"/#{account}/settings/connectivity/edit")
  end
end
