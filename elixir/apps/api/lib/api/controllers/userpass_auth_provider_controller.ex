defmodule API.UserpassAuthProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Userpass, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Userpass Auth Providers"]

  operation :index,
    summary: "List Userpass Auth Providers",
    responses: [
      ok:
        {"Userpass Auth Provider Response", "application/json",
         API.Schemas.UserpassAuthProvider.ListResponse}
    ]

  def index(conn, _params) do
    providers =
      from(p in Userpass.AuthProvider, as: :providers, order_by: [desc: p.inserted_at])
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, providers: providers)
  end

  operation :show,
    summary: "Show Userpass Auth Provider",
    parameters: [
      id: [
        in: :path,
        description: "Userpass Auth Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Userpass Auth Provider Response", "application/json",
         API.Schemas.UserpassAuthProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    provider =
      from(p in Userpass.AuthProvider, where: p.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, provider: provider)
  end
end
