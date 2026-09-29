defmodule PortalAPI.SophosPostureProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias PortalAPI.JSON
  alias __MODULE__.Database

  tags ["Sophos Posture Providers"]

  plug :require_device_posture

  defp require_device_posture(conn, _opts) do
    if Portal.Account.device_posture_enabled?(conn.assigns.subject.account) do
      conn
    else
      conn
      |> Error.handle({:error, :forbidden, reason: "This feature is not enabled for your account."})
      |> Plug.Conn.halt()
    end
  end

  # coveralls-ignore-start
  operation :index,
    summary: "List Sophos posture providers",
    parameters: [
      limit: [in: :query, description: "Limit providers returned", schema: PortalAPI.Pagination.limit_schema()],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Sophos posture provider response", "application/json",
           PortalAPI.Schemas.SophosPostureProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a Sophos posture provider",
    parameters: [
      id: [in: :path, description: "Sophos posture provider ID", type: :string]
    ],
    responses:
      [
        ok:
          {"Sophos posture provider response", "application/json",
           PortalAPI.Schemas.SophosPostureProvider.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  def index(conn, params) do
    with {:ok, opts} <- Pagination.params_to_list_opts(params),
         {:ok, providers, metadata} <- Database.list_providers(conn.assigns.subject, opts) do
      json(conn, JSON.encode(providers, metadata))
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Database.fetch_provider(id, conn.assigns.subject) do
      json(conn, JSON.encode(provider))
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, Sophos}

    def list_providers(subject, opts) do
      from(p in Sophos.PostureProvider, as: :sophos_posture_providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, Keyword.put(opts, :preload, :posture_provider))
    end

    def fetch_provider(id, subject) do
      case from(p in Sophos.PostureProvider,
             where: p.id == ^id,
             preload: [:posture_provider]
           )
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        provider -> {:ok, provider}
      end
    end

    def cursor_fields do
      [
        {:sophos_posture_providers, :desc, :inserted_at},
        {:sophos_posture_providers, :desc, :id}
      ]
    end

    def preloads, do: []
  end
end
