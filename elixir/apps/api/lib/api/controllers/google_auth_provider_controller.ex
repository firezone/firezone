defmodule API.GoogleAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Google, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Google Auth Providers"]

  operation :index,
    summary: "List Google Auth Providers",
    responses: [
      ok:
        {"Google Auth Provider Response", "application/json",
         API.Schemas.GoogleAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    query = from(p in Google.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
    providers = Safe.scoped(conn.assigns.subject) |> Safe.all(query)
    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Google Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Google Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Google Auth Provider Response", "application/json",
         API.Schemas.GoogleAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    query = from(p in Google.AuthProvider, where: p.id == ^id)
    provider = Safe.scoped(conn.assigns.subject) |> Safe.one!(query)
    render(conn, :show, provider: provider)
  end
end
