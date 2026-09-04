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

  def call(conn, opts) do
    as = Keyword.get(opts, :as)

    redirect_params =
      conn
      |> maybe_store_return_to()
      |> maybe_put_as(as)

    redirect_to = ~p"/#{conn.path_params["account_id_or_slug"]}/sign_in?#{redirect_params}"

    conn
    |> maybe_warn(as)
    |> redirect(to: redirect_to)
    |> halt()
  end

  defp maybe_store_return_to(%Plug.Conn{method: "GET"} = conn) do
    %{"redirect_to" => current_path(conn)}
  end

  defp maybe_store_return_to(_conn), do: %{}

  defp maybe_put_as(params, nil), do: params
  defp maybe_put_as(params, as), do: Map.put(params, "as", as)

  # A route that names its own sign-in flow is sending people there as a step,
  # not turning them away, and that flow explains itself on the page. Only the
  # plain case has something to warn about.
  defp maybe_warn(conn, nil),
    do: put_flash(conn, :error, "You must sign in to access that page.")

  defp maybe_warn(conn, _as), do: conn
end
