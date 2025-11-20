defmodule API.OktaAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Okta, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Okta Auth Providers"]

  operation :index,
    summary: "List Okta Auth Providers",
    responses: [
      ok:
        {"Okta Auth Provider Response", "application/json",
         API.Schemas.OktaAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    query = from(p in Okta.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
    providers = Safe.scoped(conn.assigns.subject) |> Safe.all(query)
    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Okta Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Okta Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Okta Auth Provider Response", "application/json", API.Schemas.OktaAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    query = from(p in Okta.AuthProvider, where: p.id == ^id)
    provider = Safe.scoped(conn.assigns.subject) |> Safe.one!(query)
    render(conn, :show, provider: provider)
  end
end
