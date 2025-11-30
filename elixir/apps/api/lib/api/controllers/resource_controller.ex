defmodule API.ResourceController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias __MODULE__.DB

  action_fallback API.FallbackController

  tags ["Resources"]

  operation :index,
    summary: "List Resources",
    parameters: [
      limit: [in: :query, description: "Limit Resources returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Resource Response", "application/json", API.Schemas.Resource.ListResponse}
    ]

  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, resources, metadata} <-
           DB.list_resources(conn.assigns.subject, list_opts) do
      render(conn, :index, resources: resources, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Resource Response", "application/json", API.Schemas.Resource.Response}
    ]

  def show(conn, %{"id" => id}) do
    resource = DB.fetch_resource(conn.assigns.subject, id)
    render(conn, :show, resource: resource)
  end

  operation :create,
    summary: "Create Resource",
    parameters: [],
    request_body:
      {"Resource Attributes", "application/json", API.Schemas.Resource.Request, required: true},
    responses: [
      ok: {"Resource Response", "application/json", API.Schemas.Resource.Response}
    ]

  def create(conn, %{"resource" => params}) do
    attrs = set_param_defaults(params)
    changeset = create_changeset(attrs, conn.assigns.subject)

    with {:ok, resource} <- DB.insert_resource(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/resources/#{resource}")
      |> render(:show, resource: resource)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update,
    summary: "Update Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Resource Attributes", "application/json", API.Schemas.Resource.Request, required: true},
    responses: [
      ok: {"Resource Response", "application/json", API.Schemas.Resource.Response}
    ]

  def update(conn, %{"id" => id, "resource" => params}) do
    subject = conn.assigns.subject
    attrs = set_param_defaults(params)
    resource = DB.fetch_resource(subject, id)

    with {:ok, updated_resource} <- DB.update_resource(resource, attrs, subject) do
      render(conn, :show, resource: updated_resource)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation :delete,
    summary: "Delete Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Resource Response", "application/json", API.Schemas.Resource.Response}
    ]

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject
    resource = DB.fetch_resource(subject, id)

    with {:ok, resource} <- DB.delete_resource(resource, subject) do
      render(conn, :show, resource: resource)
    end
  end

  defp set_param_defaults(params) do
    Map.put_new(params, "filters", %{})
  end

  defp create_changeset(attrs, subject) do
    account = subject.account

    %Domain.Resource{connections: []}
    |> Ecto.Changeset.cast(attrs, ~w[address address_description name type ip_stack]a)
    |> Domain.Resource.changeset()
    |> Ecto.Changeset.validate_required(~w[name type]a)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Domain.Resource.validate_address(account)
    |> Ecto.Changeset.cast_assoc(:connections,
      with: &Domain.Resources.Connection.Changeset.changeset(account.id, &1, &2, subject),
      required: true
    )
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe

    def list_resources(subject, opts \\ []) do
      from(r in Domain.Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_resource(subject, id) do
      from(r in Domain.Resource, where: r.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_resource(resource, attrs, subject) do
      resource
      |> changeset(attrs, subject)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_resource(resource, subject) do
      resource
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def insert_resource(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    defp changeset(resource, attrs, subject) do
      update_fields = ~w[address address_description name type ip_stack]a
      required_fields = ~w[name type]a

      resource
      |> Ecto.Changeset.cast(attrs, update_fields)
      |> Ecto.Changeset.validate_required(required_fields)
      |> Domain.Resource.validate_address(subject.account)
      |> Domain.Resource.changeset()
      |> Ecto.Changeset.cast_assoc(:connections,
        with:
          &Domain.Resources.Connection.Changeset.changeset(resource.account_id, &1, &2, subject),
        required: true
      )
    end

    def cursor_fields do
      [
        {:resources, :asc, :inserted_at},
        {:resources, :asc, :id}
      ]
    end
  end
end
