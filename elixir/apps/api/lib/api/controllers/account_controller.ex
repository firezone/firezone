defmodule API.AccountController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.Accounts

  action_fallback API.FallbackController

  tags ["Account"]

  operation :show,
    summary: "Show Account",
    responses: [
      ok: {"AccountResponse", "application/json", API.Schemas.Account.Response}
    ]

  # Show the current Account
  def show(conn, _params) do
    with {:ok, account} <-
           Accounts.fetch_account_by_id(conn.assigns.subject.account_id, conn.assigns.subject) do
      render(conn, :show, account: account)
    end
  end
end
