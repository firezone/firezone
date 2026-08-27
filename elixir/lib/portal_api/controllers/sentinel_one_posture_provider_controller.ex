defmodule PortalAPI.SentinelOnePostureProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias __MODULE__.Database

  tags ["SentinelOne Posture Providers"]

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
    summary: "List SentinelOne posture providers",
    parameters: [
      limit: [in: :query, description: "Limit providers returned", type: :integer],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a SentinelOne posture provider",
    parameters: [
      id: [in: :path, description: "SentinelOne posture provider ID", type: :string]
    ],
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.Response}
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
      render(conn, :index, providers: providers, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Database.fetch_provider(id, conn.assigns.subject) do
      render(conn, :show, provider: provider)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, SentinelOne}

    def list_providers(subject, opts) do
      from(p in SentinelOne.PostureProvider, as: :sentinelone_posture_providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, Keyword.put(opts, :preload, :posture_provider))
    end

    def fetch_provider(id, subject) do
      case from(p in SentinelOne.PostureProvider,
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
        {:sentinelone_posture_providers, :desc, :inserted_at},
        {:sentinelone_posture_providers, :desc, :id}
      ]
    end

    def preloads, do: []
  end
end
