defmodule FzHttpWeb.AuthView do
  use FzHttpWeb, :view

  @doc """
  Magic link is shown if:

  1. Local auth is enabled
  2. Outbound email is configured
  """
  def magic_link_active? do
    FzHttp.Config.fetch_env!(:fz_http, :local_auth_enabled) and
      not is_nil(FzHttp.Config.fetch_env!(:fz_http, FzHttpWeb.Mailer)[:from_email])
  end
end
