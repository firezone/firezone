defmodule PortalWeb.LiveHooks.PutDynamicRepo do
  @sandbox Application.compile_env(:portal, :sql_sandbox)

  def on_mount(:default, _params, _session, socket) do
    unless @sandbox do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Web)
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Web)
    end

    {:cont, socket}
  end
end
