defmodule Web.HomeController do
  use Web, :controller
  alias Domain.Accounts

  def home(conn, params) do
    {accounts, conn} =
      with {:ok, recent_account_ids, conn} <- Web.Auth.list_recent_account_ids(conn),
           {:ok, accounts} <- Accounts.list_accounts_by_ids(recent_account_ids) do
        conn =
          Web.Auth.update_recent_account_ids(conn, fn _recent_account_ids ->
            Enum.map(accounts, & &1.id)
          end)

        {accounts, conn}
      else
        _other -> {[], conn}
      end

    redirect_params =
      take_non_empty_params(params, ["client_platform", "client_csrf_token"])

    conn
    |> put_layout(html: {Web.Layouts, :public})
    |> render("home.html", accounts: accounts, redirect_params: redirect_params)
  end

  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    redirect_params =
      take_non_empty_params(params, ["client_platform", "client_csrf_token"])

    redirect(conn, to: ~p"/#{account_id_or_slug}?#{redirect_params}")
  end

  defp take_non_empty_params(map, keys) do
    map |> Map.take(keys) |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end
end
