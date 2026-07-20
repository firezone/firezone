defmodule PortalAPI.GoogleDirectoryController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.Pagination
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Google Directories"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Google Directories",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Google Directories returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Google Directory Response", "application/json",
           PortalAPI.Schemas.GoogleDirectory.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, directories, metadata} <-
           Database.list_directories(conn.assigns.subject, list_opts) do
      render(conn, :index, directories: directories, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [
        ok:
          {"Google Directory Response", "application/json",
           PortalAPI.Schemas.GoogleDirectory.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, directory} <- Database.fetch_directory(id, conn.assigns.subject) do
      render(conn, :show, directory: directory)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Google, Safe}

    def list_directories(subject, opts \\ []) do
      from(d in Google.Directory, as: :directories)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:directories, :desc, :inserted_at},
        {:directories, :desc, :id}
      ]
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
