defmodule API.OktaDirectoryController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Okta, Safe}
  alias __MODULE__.Query
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Okta Directories"]

  operation :index,
    summary: "List Okta Directories",
    responses: [
      ok: {"Okta Directory Response", "application/json", API.Schemas.OktaDirectory.ListResponse}
    ]

  def index(conn, _params) do
    directories = Query.list_directories(conn.assigns.subject)
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
    directory = Query.fetch_directory(conn.assigns.subject, id)
    render(conn, :show, directory: directory)
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.{Okta, Safe}

    def list_directories(subject) do
      from(d in Okta.Directory, as: :directories, order_by: [desc: d.inserted_at])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def fetch_directory(subject, id) do
      from(d in Okta.Directory, where: d.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end
  end
end
