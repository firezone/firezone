defmodule FzHttp.OIDC.StartProxy do
  @moduledoc """
  This proxy simply gets the relevant config at an appropriate timing
  (after `FzHttp.Conf.Cache` has started) and pass to `OpenIDConnect.Worker`'s own child_spec/1
  """

  def child_spec(_) do
    openid_connect_providers = FzHttp.Conf.get(:openid_connect_providers)
    OpenIDConnect.Worker.child_spec(openid_connect_providers)
  end
end
