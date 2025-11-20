defmodule API.GoogleDirectoryController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Google, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Google Directories"]

  operation :index,
    summary: "List Google Directories",
    responses: [
      ok:
        {"Google Directory Response", "application/json",
         API.Schemas.GoogleDirectory.ListResponse}
    ]

  def index(conn, _params) do
    directories =
      from(d in Google.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, directories: directories)
  end

  operation :show,
    summary: "Show Google Directory",
    parameters: [
      id: [
        in: :path,
        description: "Google Directory ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Google Directory Response", "application/json", API.Schemas.GoogleDirectory.Response}
    ]

  def show(conn, %{"id" => id}) do
    directory =
      from(d in Google.Directory, where: d.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, directory: directory)
  end
end
