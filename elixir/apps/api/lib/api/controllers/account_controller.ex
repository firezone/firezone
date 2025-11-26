defmodule API.AccountController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.Accounts
  alias __MODULE__.DB

  action_fallback API.FallbackController

  tags ["Account"]

  operation :show,
    summary: "Show Account",
    responses: [
      ok: {"AccountResponse", "application/json", API.Schemas.Account.Response}
    ]

  # Show the current Account
  def show(conn, _params) do
    account_id = conn.assigns.subject.account.id

    account = DB.get_account_by_id!(account_id, conn.assigns.subject)
    render(conn, :show, account: account)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Accounts.Account

    def get_account_by_id!(id, subject) do
      from(a in Account, where: a.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end
  end
end
