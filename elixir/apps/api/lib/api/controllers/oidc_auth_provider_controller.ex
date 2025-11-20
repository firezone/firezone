defmodule API.OIDCAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{OIDC, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["OIDC Auth Providers"]

  operation :index,
    summary: "List OIDC Auth Providers",
    responses: [
      ok:
        {"OIDC Auth Provider Response", "application/json",
         API.Schemas.OIDCAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    providers =
      from(p in OIDC.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show OIDC Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "OIDC Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"OIDC Auth Provider Response", "application/json", API.Schemas.OIDCAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    provider =
      from(p in OIDC.AuthProvider, where: p.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, provider: provider)
  end
end
