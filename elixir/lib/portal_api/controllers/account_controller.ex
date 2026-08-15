defmodule PortalAPI.AccountController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
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
    subject = conn.assigns.subject

    with {:ok, account} <- Database.fetch_account(subject.account.id, subject) do
      render(conn, :show, account: account)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def fetch_account(id, subject) do
      result =
        from(a in Account, where: a.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        %Account{} = account -> {:ok, account}
      end
    end
  end
end
