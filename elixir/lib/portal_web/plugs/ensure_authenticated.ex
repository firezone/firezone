defmodule PortalWeb.Plugs.EnsureAuthenticated do
  @behaviour Plug

  use PortalWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Portal.Authentication.Subject

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{subject: %Subject{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    redirect_params = maybe_store_return_to(conn)
    redirect_to = ~p"/#{conn.path_params["account_id_or_slug"]}?#{redirect_params}"

    conn
    |> put_flash(:error, "You must sign in to access that page.")
    |> redirect(to: redirect_to)
    |> halt()
  end

  defp maybe_store_return_to(%Plug.Conn{method: "GET"} = conn) do
    %{"redirect_to" => current_path(conn)}
  end

  defp maybe_store_return_to(_conn), do: %{}
end
