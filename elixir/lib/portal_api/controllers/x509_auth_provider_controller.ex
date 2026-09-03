defmodule PortalAPI.X509AuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.Render
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["X.509 Auth Providers"]

  # coveralls-ignore-start
  operation :show,
    summary: "Show X.509 Auth Provider",
    responses:
      [
        ok:
          {"X.509 Auth Provider Response", "application/json",
           PortalAPI.Schemas.X509AuthProvider.Response}
      ] ++ ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  def show(conn, _params) do
    if Portal.Features.enabled?(:trust_anchors) do
      with {:ok, provider} <- Database.fetch_provider(conn.assigns.subject) do
        Render.one(conn, provider)
      else
        error -> Error.handle(conn, error)
      end
    else
      Error.handle(conn, {:error, :not_found})
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, X509}

    def fetch_provider(subject) do
      result =
        from(p in X509.AuthProvider)
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
