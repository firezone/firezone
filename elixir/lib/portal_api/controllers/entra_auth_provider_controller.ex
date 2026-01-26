defmodule PortalAPI.EntraAuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["Entra Auth Providers"]

  operation :index,
    summary: "List Entra Auth Providers",
    responses: [
      ok:
        {"Entra Auth Provider Response", "application/json",
         PortalAPI.Schemas.EntraAuthProvider.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    providers = Database.list_providers(conn.assigns.subject)
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
         PortalAPI.Schemas.EntraAuthProvider.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Database.fetch_provider(id, conn.assigns.subject) do
      render(conn, :show, provider: provider)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Entra, Repo, Authorization}

    def list_providers(subject) do
      Authorization.with_subject(subject, fn ->
        from(p in Entra.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
        |> Repo.all()
      end)
    end

    def fetch_provider(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(p in Entra.AuthProvider, where: p.id == ^id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          provider -> {:ok, provider}
        end
      end)
    end
  end
end
