defmodule FzHttpWeb.UserView do
  @moduledoc """
  Helper functions for User views.
  """
  use FzHttpWeb, :view

  alias FzHttp.{Sites, Users}

  def admin_email do
    Application.fetch_env!(:fz_http, :admin_email)
  end

  def vpn_sessions_expire? do
    Sites.vpn_sessions_expire?()
  end

  def vpn_expires_at(user) do
    Users.vpn_session_expires_at(user, Sites.vpn_duration())
  end

  def vpn_expired?(user) do
    Users.vpn_session_expired?(user, Sites.vpn_duration())
  end
end
