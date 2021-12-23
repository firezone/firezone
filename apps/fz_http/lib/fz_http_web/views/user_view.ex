defmodule FzHttpWeb.UserView do
  @moduledoc """
  Helper functions for User views.
  """
  use FzHttpWeb, :view

  alias FzHttp.{Settings, Users}

  def admin_email do
    Users.admin().email
  end

  def vpn_sessions_expire? do
    Settings.vpn_sessions_expire?()
  end

  def vpn_expires_at(user) do
    Users.vpn_session_expires_at(user)
  end

  def vpn_expired?(user) do
    Users.vpn_session_expired?(user)
  end
end
