defmodule API.EntraDirectoryController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Entra, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Entra Directories"]

  operation :index,
    summary: "List Entra Directories",
    responses: [
      ok:
        {"Entra Directory Response", "application/json", API.Schemas.EntraDirectory.ListResponse}
    ]

  def index(conn, _params) do
    query = from(d in Entra.Directory, as: :directories, order_by: [desc: d.inserted_at])
    directories = Safe.scoped(conn.assigns.subject) |> Safe.all(query)
    render(conn, :index, directories: directories)
  end

  operation :show,
    summary: "Show Entra Directory",
    parameters: [
      id: [
        in: :path,
        description: "Entra Directory ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Entra Directory Response", "application/json", API.Schemas.EntraDirectory.Response}
    ]

  def show(conn, %{"id" => id}) do
    query = from(d in Entra.Directory, where: d.id == ^id)
    directory = Safe.scoped(conn.assigns.subject) |> Safe.one!(query)
    render(conn, :show, directory: directory)
  end
end
