defmodule PortalWeb.Plugs.EnsureAdmin do
  @behaviour Plug

  import Plug.Conn

  alias Portal.Auth.Subject
  alias Portal.Actor

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          assigns: %{subject: %Subject{actor: %Actor{type: :account_admin_user}}}
        } = conn,
        _opts
      ) do
    conn
  end

  def call(conn, _opts) do
    conn
    |> PortalWeb.Error.handle({:error, :not_found})
    |> halt()
  end
end
