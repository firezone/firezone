defmodule API.AccountController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
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

    with {:ok, account} <- DB.fetch_account(account_id, conn.assigns.subject) do
      render(conn, :show, account: account)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Account

    def fetch_account(id, subject) do
      result =
        from(a in Account, where: a.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        account -> {:ok, account}
      end
    end
  end
end
