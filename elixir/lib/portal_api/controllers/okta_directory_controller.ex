defmodule PortalAPI.OktaDirectoryController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias __MODULE__.Database

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
    directories = Database.list_directories(conn.assigns.subject)
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
    with {:ok, directory} <- Database.fetch_directory(id, conn.assigns.subject) do
      render(conn, :show, directory: directory)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Okta, Repo, Authorization}

    def list_directories(subject) do
      Authorization.with_subject(subject, fn ->
        from(d in Okta.Directory, as: :directories, order_by: [desc: d.inserted_at])
        |> Repo.all()
      end)
    end

    def fetch_directory(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(d in Okta.Directory, where: d.id == ^id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          directory -> {:ok, directory}
        end
      end)
    end
  end
end
