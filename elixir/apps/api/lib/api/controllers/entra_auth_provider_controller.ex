defmodule API.EntraAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Entra, Safe}
  alias __MODULE__.DB
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
    providers = DB.list_providers(conn.assigns.subject)
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
    provider = DB.fetch_provider(conn.assigns.subject, id)
    render(conn, :show, provider: provider)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Entra, Safe}

    def list_providers(subject) do
      from(p in Entra.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_provider(subject, id) do
      from(p in Entra.AuthProvider, where: p.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end
  end
end
