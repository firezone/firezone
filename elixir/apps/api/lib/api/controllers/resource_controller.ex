defmodule API.ResourceController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Resources

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
           Resources.list_resources(conn.assigns.subject, list_opts) do
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
    with {:ok, resource} <-
           Resources.fetch_resource_by_id_or_persistent_id(id, conn.assigns.subject) do
      render(conn, :show, resource: resource)
    end
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

    with {:ok, resource} <- Resources.create_resource(attrs, conn.assigns.subject) do
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

    with {:ok, resource} <- Resources.fetch_resource_by_id_or_persistent_id(id, subject) do
      case Resources.update_or_replace_resource(resource, attrs, subject) do
        {:updated, updated_resource} ->
          render(conn, :show, resource: updated_resource)

        {:replaced, _updated_resource, created_resource} ->
          render(conn, :show, resource: created_resource)

        {:error, reason} ->
          {:error, reason}
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
      ok: {"Resource Response", "application/json", API.Schemas.Resource.Response}
    ]

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Resources.fetch_resource_by_id_or_persistent_id(id, subject),
         {:ok, resource} <- Resources.delete_resource(resource, subject) do
      render(conn, :show, resource: resource)
    end
  end

  defp set_param_defaults(params) do
    Map.put_new(params, "filters", %{})
  end
end
