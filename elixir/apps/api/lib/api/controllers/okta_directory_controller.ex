defmodule API.OktaDirectoryController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Okta, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Okta Directories"]

  operation :index,
    summary: "List Okta Directories",
    responses: [
      ok: {"Okta Directory Response", "application/json", API.Schemas.OktaDirectory.ListResponse}
    ]

  def index(conn, _params) do
    directories =
      from(d in Okta.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, directories: directories)
  end

  operation :show,
    summary: "Show Okta Directory",
    parameters: [
      id: [
        in: :path,
        description: "Okta Directory ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Okta Directory Response", "application/json", API.Schemas.OktaDirectory.Response}
    ]

  def show(conn, %{"id" => id}) do
    directory =
      from(d in Okta.Directory, where: d.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, directory: directory)
  end
end
