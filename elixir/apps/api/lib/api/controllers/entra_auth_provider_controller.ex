defmodule API.EntraAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Entra, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Entra Auth Providers"]

  operation :index,
    summary: "List Entra Auth Providers",
    responses: [
      ok:
        {"Entra Auth Provider Response", "application/json",
         API.Schemas.EntraAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    query = from(p in Entra.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
    providers = Safe.scoped(conn.assigns.subject) |> Safe.all(query)
    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Entra Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Entra Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Entra Auth Provider Response", "application/json",
         API.Schemas.EntraAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    query = from(p in Entra.AuthProvider, where: p.id == ^id)
    provider = Safe.scoped(conn.assigns.subject) |> Safe.one!(query)
    render(conn, :show, provider: provider)
  end
end
