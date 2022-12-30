defmodule FzHttpWeb.OIDC.Helpers do
  @moduledoc """
  Just some, ya know, helpers for OIDC flows.
  """

  # openid_connect expects providers as keys...
  def atomize_provider(key) do
    # XXX: This needs to be an atom due to the underlying library.
    # Update the library to be a String
    {:ok, String.to_atom(key)}
  rescue
    ArgumentError -> {:error, "OIDC Provider not found"}
  end

  def openid_connect do
    FzHttp.Config.fetch_env!(:fz_http, :openid_connect)
  end
end
