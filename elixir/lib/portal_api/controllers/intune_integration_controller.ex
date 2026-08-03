defmodule PortalAPI.IntuneIntegrationController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Schemas.ProblemDetails}
  alias __MODULE__.Database

  tags ["Intune Integrations"]

  # coveralls-ignore-start
  operation :index,
    summary: "List Intune device inventory integrations",
    responses:
      [
        ok:
          {"Intune integration response", "application/json",
           PortalAPI.Schemas.IntuneIntegration.ListResponse}
      ] ++ ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  operation :show,
    summary: "Show an Intune device inventory integration",
    parameters: [
      id: [in: :path, description: "Intune integration ID", type: :string]
    ],
    responses:
      [
        ok:
          {"Intune integration response", "application/json",
           PortalAPI.Schemas.IntuneIntegration.Response}
      ] ++ ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  def index(conn, _params) do
    integrations = Database.list_integrations(conn.assigns.subject)
    render(conn, :index, integrations: integrations)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, integration} <- Database.fetch_integration(id, conn.assigns.subject) do
      render(conn, :show, integration: integration)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Intune, Safe}

    def list_integrations(subject) do
      from(i in Intune.Integration, order_by: [desc: i.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_integration(id, subject) do
      case from(i in Intune.Integration, where: i.id == ^id)
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        integration -> {:ok, integration}
      end
    end
  end
end
