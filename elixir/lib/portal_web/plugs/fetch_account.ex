defmodule PortalWeb.Plugs.FetchAccount do
  @behaviour Plug

  use PortalWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [account_id_or_slug | rest]} = conn, _opts) do
    case PortalWeb.Accounts.get_by_id_or_slug(account_id_or_slug) do
      %Portal.Account{} = account ->
        conn
        |> assign(:account, account)
        |> maybe_redirect_old_slug(account_id_or_slug, rest, account)

      nil ->
        handle_missing_account(conn)
    end
  end

  def call(conn, _opts), do: conn

  # An old slug still resolves, but GET requests move to the current slug so
  # bookmarks and links heal themselves. Other methods keep going as they are.
  defp maybe_redirect_old_slug(%Plug.Conn{method: method} = conn, account_id_or_slug, rest, account)
       when method in ["GET", "HEAD"] do
    if PortalWeb.Accounts.old_slug?(account_id_or_slug, account) do
      conn
      |> redirect(to: PortalWeb.Accounts.current_path(account, rest, conn.query_string))
      |> halt()
    else
      conn
    end
  end

  defp maybe_redirect_old_slug(conn, _account_id_or_slug, _rest, _account), do: conn

  defp handle_missing_account(conn) do
    case missing_client_sign_in_redirect(conn) do
      {:redirect, conn} -> conn
      :noop -> conn
    end
  end

  defp missing_client_sign_in_redirect(
         %{path_info: [_account_id_or_slug, "sign_in" | _rest], params: params} = conn
       ) do
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    if PortalWeb.Authentication.client_sign_in?(sign_in_params) do
      {:redirect,
       conn
       |> redirect(to: ~p"/sign_in?#{sign_in_params}")
       |> halt()}
    else
      :noop
    end
  end

  defp missing_client_sign_in_redirect(_conn), do: :noop

end
