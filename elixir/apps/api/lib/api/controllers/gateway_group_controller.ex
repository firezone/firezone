defmodule API.GatewayGroupController do
  alias Domain.Gateways
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Gateway Groups / Sites
  def index(conn, params) do
    list_opts = params_to_list_opts(params)

    with {:ok, gateway_groups, metadata} <- Gateways.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, gateway_groups: gateway_groups, metadata: metadata)
    end
  end

  # Show a specific Gateway Group / Site
  def show(conn, %{"id" => id}) do
    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(id, conn.assigns.subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  # Create a new Gateway Group / Site
  def create(conn, %{"gateway_group" => params}) do
    with {:ok, gateway_group} <- Gateways.create_group(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/gateway_groups/#{gateway_group}")
      |> render(:show, gateway_group: gateway_group)
    end
  end

  # Update a Gateway Group / Site
  def update(conn, %{"id" => id, "gateway_group" => params}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(id, subject),
         {:ok, gateway_group} <- Gateways.update_group(gateway_group, params, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  # Delete a Gateway Group / Site
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(id, subject),
         {:ok, gateway_group} <- Gateways.delete_group(gateway_group, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end
end
