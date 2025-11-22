defmodule API.EntraDirectoryController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Entra, Safe}
  alias __MODULE__.Query
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
    directories = Query.list_directories(conn.assigns.subject)
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
      ok: {"Entra Directory Response", "application/json", API.Schemas.EntraDirectory.Response}
    ]

  def show(conn, %{"id" => id}) do
    directory = Query.fetch_directory(conn.assigns.subject, id)
    render(conn, :show, directory: directory)
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.{Entra, Safe}

    def list_directories(subject) do
      from(d in Entra.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_directory(subject, id) do
      from(d in Entra.Directory, where: d.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end
  end
end
