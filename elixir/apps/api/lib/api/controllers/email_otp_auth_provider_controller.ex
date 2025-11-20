defmodule API.EmailOTPAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{EmailOTP, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Email OTP Auth Providers"]

  operation :index,
    summary: "List Email OTP Auth Providers",
    responses: [
      ok:
        {"Email OTP Auth Provider Response", "application/json",
         API.Schemas.EmailOTPAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    query = from(p in EmailOTP.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
    providers = Safe.scoped(conn.assigns.subject) |> Safe.all(query)
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
         API.Schemas.EmailOTPAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    query = from(p in EmailOTP.AuthProvider, where: p.id == ^id)
    provider = Safe.scoped(conn.assigns.subject) |> Safe.one!(query)
    render(conn, :show, provider: provider)
  end
end
