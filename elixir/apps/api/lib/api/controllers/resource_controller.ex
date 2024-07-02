defmodule API.ResourceController do
  use API, :controller
  alias API.Pagination
  alias Domain.Resources

  action_fallback API.FallbackController

  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, resources, metadata} <-
           Resources.list_resources(conn.assigns.subject, list_opts) do
      render(conn, :index, resources: resources, metadata: metadata)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- Resources.fetch_resource_by_id(id, conn.assigns.subject) do
      render(conn, :show, resource: resource)
    end
  end

  def create(conn, %{"resource" => params}) do
    attrs = set_param_defaults(params)

    with {:ok, resource} <- Resources.create_resource(attrs, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/resources/#{resource}")
      |> render(:show, resource: resource)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  def update(conn, %{"id" => id, "resource" => params}) do
    subject = conn.assigns.subject
    attrs = set_param_defaults(params)

    with {:ok, resource} <- Resources.fetch_resource_by_id(id, subject),
         {:ok, resource} <- Resources.update_resource(resource, attrs, subject) do
      render(conn, :show, resource: resource)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Resources.fetch_resource_by_id(id, subject),
         {:ok, resource} <- Resources.delete_resource(resource, subject) do
      render(conn, :show, resource: resource)
    end
  end

  defp set_param_defaults(params) do
    Map.put_new(params, "filters", %{})
  end
end
