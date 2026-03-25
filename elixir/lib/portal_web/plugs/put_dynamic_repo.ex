defmodule PortalWeb.Plugs.PutDynamicRepo do
  @behaviour Plug

  @sandbox Application.compile_env(:portal, :sql_sandbox)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    unless @sandbox do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Web)
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Web)
    end

    conn
  end
end
