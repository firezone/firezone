defmodule Web.HomeController do
  use Web, :controller
  alias Domain.Accounts

  def home(conn, params) do
    signed_in_account_ids = conn |> get_session("sessions", []) |> Enum.map(&elem(&1, 0))

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

    params = Web.Auth.take_sign_in_params(params)

    conn
    |> put_layout(html: {Web.Layouts, :public})
    |> render("home.html",
      accounts: accounts,
      signed_in_account_ids: signed_in_account_ids,
      params: params
    )
  end

  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params) do
    params = Web.Auth.take_sign_in_params(params)

    case Domain.Accounts.Account.Changeset.validate_account_id_or_slug(account_id_or_slug) do
      {:ok, account_id_or_slug} ->
        redirect(conn, to: ~p"/#{account_id_or_slug}?#{params}")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/?#{params}")
    end
  end
end
