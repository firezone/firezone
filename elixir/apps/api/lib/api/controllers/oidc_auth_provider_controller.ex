defmodule API.OIDCAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{OIDC, Safe}
  alias __MODULE__.DB
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
    providers = DB.list_providers(conn.assigns.subject)
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
    provider = DB.fetch_provider(conn.assigns.subject, id)
    render(conn, :show, provider: provider)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{OIDC, Safe}

    def list_providers(subject) do
      from(p in OIDC.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_provider(subject, id) do
      from(p in OIDC.AuthProvider, where: p.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end
  end
end
