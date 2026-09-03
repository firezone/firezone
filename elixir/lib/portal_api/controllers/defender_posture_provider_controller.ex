defmodule PortalAPI.DefenderPostureProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias PortalAPI.Render
  alias __MODULE__.Database

  tags ["Defender Posture Providers"]

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
    summary: "List Defender posture providers",
    parameters: [
      limit: [in: :query, description: "Limit providers returned", type: :integer],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Defender posture provider response", "application/json",
           PortalAPI.Schemas.DefenderPostureProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a Defender posture provider",
    parameters: [
      id: [in: :path, description: "Defender posture provider ID", type: :string]
    ],
    responses:
      [
        ok:
          {"Defender posture provider response", "application/json",
           PortalAPI.Schemas.DefenderPostureProvider.Response}
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
      Render.list(conn, providers, metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Database.fetch_provider(id, conn.assigns.subject) do
      Render.one(conn, provider)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Defender, Safe}

    def list_providers(subject, opts) do
      from(p in Defender.PostureProvider, as: :defender_posture_providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, Keyword.put(opts, :preload, :posture_provider))
    end

    def fetch_provider(id, subject) do
      case from(p in Defender.PostureProvider, where: p.id == ^id, preload: [:posture_provider])
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        provider -> {:ok, provider}
      end
    end

    def cursor_fields do
      [
        {:defender_posture_providers, :desc, :inserted_at},
        {:defender_posture_providers, :desc, :id}
      ]
    end

    def preloads, do: []
  end
end
