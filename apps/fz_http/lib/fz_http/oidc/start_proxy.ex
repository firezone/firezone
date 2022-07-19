defmodule FzHttp.OIDC.StartProxy do
  def child_spec(_) do
    openid_connect_providers = FzHttp.Conf.get(:openid_connect_providers)
    OpenIDConnect.Worker.child_spec(openid_connect_providers)
  end
end
