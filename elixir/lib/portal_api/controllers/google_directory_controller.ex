defmodule PortalAPI.GoogleDirectoryController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.{Google, Safe}
  alias __MODULE__.DB
  import Ecto.Query

  action_fallback PortalAPI.FallbackController

  tags ["Google Directories"]

  operation :index,
    summary: "List Google Directories",
    responses: [
      ok:
        {"Google Directory Response", "application/json",
         PortalAPI.Schemas.GoogleDirectory.ListResponse}
    ]

  def index(conn, _params) do
    directories = DB.list_directories(conn.assigns.subject)
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
      ok: {"Google Directory Response", "application/json", PortalAPI.Schemas.GoogleDirectory.Response}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, directory} <- DB.fetch_directory(id, conn.assigns.subject) do
      render(conn, :show, directory: directory)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Google, Safe}

    def list_directories(subject) do
      from(d in Google.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_directory(id, subject) do
      result =
        from(d in Google.Directory, where: d.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        directory -> {:ok, directory}
      end
    end
  end
end
