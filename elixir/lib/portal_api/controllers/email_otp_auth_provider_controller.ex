defmodule PortalAPI.EmailOTPAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.{EmailOTP, Safe}
  alias __MODULE__.DB
  import Ecto.Query

  action_fallback PortalAPI.FallbackController

  tags ["Email OTP Auth Providers"]

  operation :index,
    summary: "List Email OTP Auth Providers",
    responses: [
      ok:
        {"Email OTP Auth Provider Response", "application/json",
         PortalAPI.Schemas.EmailOTPAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    providers = DB.list_providers(conn.assigns.subject)
    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Email OTP Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Email OTP Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Email OTP Auth Provider Response", "application/json",
         PortalAPI.Schemas.EmailOTPAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- DB.fetch_provider(id, conn.assigns.subject) do
      render(conn, :show, provider: provider)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{EmailOTP, Safe}

    def list_providers(subject) do
      from(p in EmailOTP.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_provider(id, subject) do
      result =
        from(p in EmailOTP.AuthProvider, where: p.id == ^id)
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
