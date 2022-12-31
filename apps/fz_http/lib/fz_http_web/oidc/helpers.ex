defmodule FzHttpWeb.OIDC.Helpers do
  @moduledoc """
  Just some, ya know, helpers for OIDC flows.
  """

  def openid_connect do
    FzHttp.Config.fetch_env!(:fz_http, :openid_connect)
  end
end
