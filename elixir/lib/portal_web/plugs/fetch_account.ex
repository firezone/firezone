defmodule PortalWeb.Plugs.FetchAccount do
  @behaviour Plug

  use PortalWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias __MODULE__.Database

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [account_id_or_slug | _rest]} = conn, _opts) do
    case Database.get_account_by_id_or_slug(account_id_or_slug) do
      %Portal.Account{} = account -> assign(conn, :account, account)
      nil -> handle_missing_account(conn)
    end
  end

  def call(conn, _opts), do: conn

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

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped(:replica) |> Safe.one()
    end
  end
end
