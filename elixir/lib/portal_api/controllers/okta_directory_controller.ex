defmodule PortalAPI.OktaDirectoryController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.DB

  tags ["Okta Directories"]

  operation :index,
    summary: "List Okta Directories",
    responses: [
      ok:
        {"Okta Directory Response", "application/json",
         PortalAPI.Schemas.OktaDirectory.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    directories = DB.list_directories(conn.assigns.subject)
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
      ok:
        {"Okta Directory Response", "application/json", PortalAPI.Schemas.OktaDirectory.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, directory} <- DB.fetch_directory(id, conn.assigns.subject) do
      render(conn, :show, directory: directory)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Okta, Safe}

    def list_directories(subject) do
      from(d in Okta.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_directory(id, subject) do
      result =
        from(d in Okta.Directory, where: d.id == ^id)
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
