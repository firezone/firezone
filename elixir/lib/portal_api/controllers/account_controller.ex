defmodule PortalAPI.AccountController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Account"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :show,
    summary: "Show Account",
    responses:
      [ok: {"AccountResponse", "application/json", PortalAPI.Schemas.Account.Response}] ++
        ProblemDetails.responses([:unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    # The subject's own account always exists and is readable by every actor type
    # (Safe.permit/3), so the fetch cannot fail here.
    account = Database.fetch_account(conn.assigns.subject.account.id, conn.assigns.subject)
    render(conn, :show, account: account)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def fetch_account(id, subject) do
      from(a in Account, where: a.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end
  end
end
