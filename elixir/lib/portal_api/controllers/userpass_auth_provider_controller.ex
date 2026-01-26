defmodule PortalAPI.UserpassAuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["Userpass Auth Providers"]

  operation :index,
    summary: "List Userpass Auth Providers",
    responses: [
      ok:
        {"Userpass Auth Provider Response", "application/json",
         PortalAPI.Schemas.UserpassAuthProvider.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    providers = Database.list_providers(conn.assigns.subject)
    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Userpass Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Userpass Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Userpass Auth Provider Response", "application/json",
         PortalAPI.Schemas.UserpassAuthProvider.Response}
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
    alias Portal.{Userpass, Repo, Authorization}

    def list_providers(subject) do
      Authorization.with_subject(subject, fn ->
        from(p in Userpass.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
        |> Repo.all()
      end)
    end

    def fetch_provider(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(p in Userpass.AuthProvider, where: p.id == ^id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          provider -> {:ok, provider}
        end
      end)
    end
  end
end
