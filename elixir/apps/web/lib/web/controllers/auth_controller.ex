defmodule Web.AuthController do
  use Web, :controller
  alias Domain.{Accounts, Auth}

  def sign_in(conn, %{
        "account_id" => account_id,
        "provider_id" => provider_id,
        "provider_identifier" => provider_identifier,
        "secret" => secret
      }) do
    with {:ok, provider} <- Auth.fetch_provider_by_id(provider_id),
         {:ok, subject} <-
           Auth.sign_in(
             provider,
             provider_identifier,
             secret,
             conn.assigns.user_agent,
             conn.assigns.remote_ip
           ) do
      conn
      |> put_session(:subject, subject)
      |> redirect(to: ~p"/#{account_id}/dashboard")
    else
      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: "/login")
    end
  end

  def sign_in(conn, %{"account_id" => account_id}) do
    with {:ok, account} <- Accounts.fetch_account_by_id(account_id),
         {:ok, providers} = Auth.list_providers_for_account(account) do
      render(conn, "login.html", account: account, providers: providers)
    end
  end

  def sign_out(conn, _params) do
    conn
    |> delete_session(:current_user)
    |> redirect(to: "/")
  end
end
