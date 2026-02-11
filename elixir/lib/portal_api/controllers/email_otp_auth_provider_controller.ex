defmodule PortalAPI.EmailOTPAuthProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["Email OTP Auth Providers"]

  operation :index,
    summary: "List Email OTP Auth Providers",
    responses: [
      ok:
        {"Email OTP Auth Provider Response", "application/json",
         PortalAPI.Schemas.EmailOTPAuthProvider.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    providers = Database.list_providers(conn.assigns.subject)
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
    alias Portal.{EmailOTP, Safe}

    def list_providers(subject) do
      from(p in EmailOTP.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def fetch_provider(id, subject) do
      result =
        from(p in EmailOTP.AuthProvider, where: p.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        provider -> {:ok, provider}
      end
    end
  end
end
