defmodule PortalAPI.OIDCAuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.JSON
  alias PortalAPI.Filters
  alias PortalAPI.Pagination
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["OIDC Auth Providers"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List OIDC Auth Providers",
    parameters: [
      limit: [
        in: :query,
        description: "Limit OIDC Auth Providers returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [
        in: :query,
        description: "Filter to OIDC Auth Providers with this exact name",
        type: :string
      ]
    ],
    responses:
      [
        ok:
          {"OIDC Auth Provider Response", "application/json",
           PortalAPI.Schemas.OIDCAuthProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, coerce_filters(params)),
         {:ok, providers, metadata} <- Database.list_providers(conn.assigns.subject, list_opts) do
      json(conn, %{data: JSON.encode(providers), metadata: Pagination.metadata(metadata)})
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params) do
    Filters.maybe_append([], :name, params["name"])
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [
        ok:
          {"OIDC Auth Provider Response", "application/json",
           PortalAPI.Schemas.OIDCAuthProvider.Response}
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
      json(conn, %{data: JSON.encode(provider)})
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{OIDC, Safe}

    def list_providers(subject, opts \\ []) do
      from(p in OIDC.AuthProvider, as: :providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Name",
          type: :string,
          fun: &filter_by_name/2
        }
      ]
    end

    defp filter_by_name(queryable, name) do
      dynamic = dynamic([providers: p], p.name == ^name)
      {queryable, dynamic}
    end

    def cursor_fields do
      [
        {:providers, :desc, :inserted_at},
        {:providers, :desc, :id}
      ]
    end

    def fetch_provider(id, subject) do
      result =
        from(p in OIDC.AuthProvider, where: p.id == ^id)
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
