defmodule FzHttpWeb.RootView do
  use FzHttpWeb, :view

  alias FzCommon.FzCrypto

  def authorization_uri(oidc, provider) do
    params = %{
      state: FzCrypto.rand_string(),
      access_type: "offline" # needed for google
    }

    oidc.authorization_uri(provider, params)
  end
end
