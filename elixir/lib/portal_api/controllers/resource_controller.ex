defmodule PortalAPI.ResourceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias __MODULE__.DB

  action_fallback PortalAPI.FallbackController

  tags ["Resources"]

  operation :index,
    summary: "List Resources",
    parameters: [
      limit: [in: :query, description: "Limit Resources returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.ListResponse}
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
      ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- DB.fetch_resource(id, conn.assigns.subject) do
      render(conn, :show, resource: resource)
    end
  end

  operation :create,
    summary: "Create Resource",
    parameters: [],
    request_body:
      {"Resource Attributes", "application/json", PortalAPI.Schemas.Resource.Request,
       required: true},
    responses: [
      ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}
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
      {"Resource Attributes", "application/json", PortalAPI.Schemas.Resource.Request,
       required: true},
    responses: [
      ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}
    ]

  def update(conn, %{"id" => id, "resource" => params}) do
    subject = conn.assigns.subject
    attrs = set_param_defaults(params)

    with {:ok, resource} <- DB.fetch_resource(id, subject) do
      # Prevent updates to Internet resource
      if resource.type == :internet do
        {:error, {:forbidden, "Internet resource cannot be updated"}}
      else
        with {:ok, updated_resource} <- DB.update_resource(resource, attrs, subject) do
          render(conn, :show, resource: updated_resource)
        end
      end
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
      ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}
    ]

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, resource} <- DB.fetch_resource(id, subject) do
      # Prevent deletion of Internet resource
      if resource.type == :internet do
        {:error, {:forbidden, "Internet resource cannot be deleted"}}
      else
        with {:ok, resource} <- DB.delete_resource(resource, subject) do
          render(conn, :show, resource: resource)
        end
      end
    end
  end

  defp set_param_defaults(params) do
    Map.put_new(params, "filters", %{})
  end

  defp create_changeset(attrs, subject) do
    %Portal.Resource{}
    |> Ecto.Changeset.cast(attrs, ~w[address address_description name type ip_stack site_id]a)
    |> Portal.Resource.changeset()
    |> Ecto.Changeset.validate_required(~w[name type site_id]a)
    |> Ecto.Changeset.put_change(:account_id, subject.account.id)
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe

    def list_resources(subject, opts \\ []) do
      from(r in Portal.Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_resource(id, subject) do
      result =
        from(r in Portal.Resource, where: r.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
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

    defp changeset(resource, attrs, _subject) do
      update_fields = ~w[address address_description name type ip_stack site_id]a
      required_fields = ~w[name type site_id]a

      resource
      |> Ecto.Changeset.cast(attrs, update_fields)
      |> Ecto.Changeset.validate_required(required_fields)
      |> Portal.Resource.changeset()
    end

    def cursor_fields do
      [
        {:resources, :asc, :inserted_at},
        {:resources, :asc, :id}
      ]
    end
  end
end
