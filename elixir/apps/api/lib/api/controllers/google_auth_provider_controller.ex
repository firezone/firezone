defmodule API.GoogleAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Google, Safe}
  alias __MODULE__.DB
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
    providers = DB.list_providers(conn.assigns.subject)
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
    with {:ok, provider} <- DB.fetch_provider(id, conn.assigns.subject) do
      render(conn, :show, provider: provider)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Google, Safe}

    def list_providers(subject) do
      from(p in Google.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_provider(id, subject) do
      result =
        from(p in Google.AuthProvider, where: p.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        provider -> {:ok, provider}
      end
    end
  end
end
