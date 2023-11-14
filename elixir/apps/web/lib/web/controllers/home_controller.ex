defmodule Web.HomeController do
  use Web, :controller
  alias Domain.Accounts

  def home(conn, _params) do
    {accounts, conn} =
      with {:ok, recent_account_ids, conn} <- Web.Auth.list_recent_account_ids(conn),
           {:ok, accounts} = Accounts.list_accounts_by_ids(recent_account_ids) do
        conn =
          Web.Auth.update_recent_account_ids(conn, fn _recent_account_ids ->
            Enum.map(accounts, & &1.id)
          end)

        {accounts, conn}
      else
        _other -> {[], conn}
      end

    conn
    |> put_layout(html: {Web.Layouts, :public})
    |> render("home.html", accounts: accounts)
  end

  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug}) do
    redirect(conn, to: ~p"/#{account_id_or_slug}")
  end
end
