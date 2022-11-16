defmodule FzHttpWeb.OIDC.Helpers do
  @moduledoc """
  Just some, ya know, helpers for OIDC flows.
  """

  # openid_connect expects providers as keys...
  def atomize_provider(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, "OIDC Provider not found"}
  end

  def openid_connect do
    Application.fetch_env!(:fz_http, :openid_connect)
  end
end
