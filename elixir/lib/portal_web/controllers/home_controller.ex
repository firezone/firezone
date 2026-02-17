defmodule PortalWeb.HomeController do
  use PortalWeb, :controller
  alias __MODULE__.Database

  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    %PortalWeb.Cookie.RecentAccounts{account_ids: recent_account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    if recent_account_ids != [] do
      redirect(conn, to: ~p"/sign_in")
    else
      redirect(conn, to: ~p"/getting_started")
    end
  end

  @spec getting_started(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def getting_started(conn, params) do
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    conn
    |> put_layout(html: {PortalWeb.Layouts, :auth})
    |> render("home.html",
      accounts: [],
      params: sign_in_params,
      show_account_chooser: false
    )
  end

  @spec sign_in_chooser(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in_chooser(conn, params) do
    %PortalWeb.Cookie.RecentAccounts{account_ids: recent_account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    recent_accounts = Database.get_accounts_by_ids(recent_account_ids)
    ids_to_remove = recent_account_ids -- Enum.map(recent_accounts, & &1.id)
    conn = PortalWeb.Cookie.RecentAccounts.remove(conn, ids_to_remove)
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    conn
    |> put_layout(html: {PortalWeb.Layouts, :auth})
    |> render("home.html",
      accounts: recent_accounts,
      params: sign_in_params,
      show_account_chooser: true
    )
  end

  @spec redirect_to_sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    params = PortalWeb.Authentication.take_sign_in_params(params)

    case validate_account_id_or_slug(account_id_or_slug) do
      {:ok, account_id_or_slug} ->
        redirect(conn, to: ~p"/#{account_id_or_slug}/sign_in?#{params}")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/sign_in?#{params}")
    end
  end

  @slug_regex ~r/^[a-zA-Z0-9_]+$/

  defp validate_account_id_or_slug(account_id_or_slug) do
    cond do
      Portal.Repo.valid_uuid?(account_id_or_slug) ->
        {:ok, String.downcase(account_id_or_slug)}

      String.match?(account_id_or_slug, @slug_regex) ->
        {:ok, String.downcase(account_id_or_slug)}

      true ->
        {:error, "Account ID or Slug can only contain letters, digits and underscore"}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_accounts_by_ids(account_ids) do
      from(a in Portal.Account, where: a.id in ^account_ids)
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
