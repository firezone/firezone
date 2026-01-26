defmodule PortalWeb.HomeController do
  use PortalWeb, :controller
  alias __MODULE__.Database

  def home(conn, params) do
    %PortalWeb.Cookie.RecentAccounts{account_ids: recent_account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    recent_accounts = Database.get_accounts_by_ids(recent_account_ids)
    ids_to_remove = recent_account_ids -- Enum.map(recent_accounts, & &1.id)
    conn = PortalWeb.Cookie.RecentAccounts.remove(conn, ids_to_remove)
    params = PortalWeb.Authentication.take_sign_in_params(params)

    conn
    |> put_layout(html: {PortalWeb.Layouts, :public})
    |> render("home.html",
      accounts: recent_accounts,
      params: params
    )
  end

  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    params = PortalWeb.Authentication.take_sign_in_params(params)

    case validate_account_id_or_slug(account_id_or_slug) do
      {:ok, account_id_or_slug} ->
        redirect(conn, to: ~p"/#{account_id_or_slug}?#{params}")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/?#{params}")
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
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
