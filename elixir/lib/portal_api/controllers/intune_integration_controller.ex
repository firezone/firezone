defmodule PortalAPI.IntuneIntegrationController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Schemas.ProblemDetails}
  alias __MODULE__.Database

  tags ["Intune Integrations"]

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
  operation :show,
    summary: "Show the Intune device inventory integration",
    description:
      "An account has at most one Intune integration, so this is a singleton rather than a collection.",
    responses:
      [
        ok:
          {"Intune integration response", "application/json",
           PortalAPI.Schemas.IntuneIntegration.Response}
      ] ++ ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  def show(conn, _params) do
    with {:ok, integration} <- Database.fetch_integration(conn.assigns.subject) do
      render(conn, :show, integration: integration)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Intune, Safe}

    def fetch_integration(subject) do
      case from(i in Intune.Integration)
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        integration -> {:ok, integration}
      end
    end
  end
end
