defmodule PortalAPI.AccountController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["Account"]

  operation :show,
    summary: "Show Account",
    responses: [
      ok: {"AccountResponse", "application/json", PortalAPI.Schemas.Account.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    account_id = conn.assigns.subject.account.id

    with {:ok, account} <- Database.fetch_account(account_id, conn.assigns.subject) do
      render(conn, :show, account: account)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Authorization, Repo}
    alias Portal.Account

    def fetch_account(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(a in Account, where: a.id == ^id)
        |> Repo.one()
      end)
      |> case do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end
  end
end
