defmodule PortalAPI.EntraDirectoryController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.JSON
  alias PortalAPI.Filters
  alias PortalAPI.Pagination
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Entra Directories"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Entra Directories",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Entra Directories returned",
        schema: PortalAPI.Pagination.limit_schema(),
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [
        in: :query,
        description: "Filter to Entra Directories with this exact name",
        type: :string
      ]
    ],
    responses:
      [
        ok:
          {"Entra Directory Response", "application/json",
           PortalAPI.Schemas.EntraDirectory.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, coerce_filters(params)),
         {:ok, directories, metadata} <-
           Database.list_directories(conn.assigns.subject, list_opts) do
      json(conn, JSON.encode(directories, metadata))
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params) do
    Filters.maybe_append([], :name, params["name"])
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [
        ok:
          {"Entra Directory Response", "application/json",
           PortalAPI.Schemas.EntraDirectory.Response}
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
      json(conn, JSON.encode(directory))
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Entra, Safe}

    def list_directories(subject, opts \\ []) do
      from(d in Entra.Directory, as: :directories)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Name",
          type: :string,
          fun: &filter_by_name/2
        }
      ]
    end

    defp filter_by_name(queryable, name) do
      dynamic = dynamic([directories: d], d.name == ^name)
      {queryable, dynamic}
    end

    def cursor_fields do
      [
        {:directories, :desc, :inserted_at},
        {:directories, :desc, :id}
      ]
    end

    def fetch_directory(id, subject) do
      result =
        from(d in Entra.Directory, where: d.id == ^id)
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
