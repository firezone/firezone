defmodule PortalWeb.Plugs.EnsureAdmin do
  @behaviour Plug

  import Plug.Conn

  alias Portal.Authentication.Subject
  alias Portal.Actor

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{
          assigns: %{subject: %Subject{actor: %Actor{type: type}}}
        } = conn,
        _opts
      )
      when type in [:account_admin_user, :firezone_support] do
    conn
  end

  def call(conn, _opts) do
    conn
    |> PortalWeb.Error.handle({:error, :not_found})
    |> halt()
  end
end
