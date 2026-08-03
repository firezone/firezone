defmodule PortalAPI.EntraAuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.Pagination
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Entra Auth Providers"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Entra Auth Providers",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Entra Auth Providers returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Entra Auth Provider Response", "application/json",
           PortalAPI.Schemas.EntraAuthProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, providers, metadata} <- Database.list_providers(conn.assigns.subject, list_opts) do
      render(conn, :index, providers: providers, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [
        ok:
          {"Entra Auth Provider Response", "application/json",
           PortalAPI.Schemas.EntraAuthProvider.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

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
    alias Portal.{Entra, Safe}

    def list_providers(subject, opts \\ []) do
      from(p in Entra.AuthProvider, as: :providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:providers, :desc, :inserted_at},
        {:providers, :desc, :id}
      ]
    end

    def fetch_provider(id, subject) do
      result =
        from(p in Entra.AuthProvider, where: p.id == ^id)
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
