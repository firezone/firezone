defmodule API.GatewayController do
  alias Domain.Gateways
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Gateways
  def index(conn, params) do
    list_opts = params_to_list_opts(params)

    with {:ok, gateways, metadata} <- Gateways.list_gateways(conn.assigns.subject, list_opts) do
      render(conn, :index, gateways: gateways, metadata: metadata)
    end
  end

  # Show a specific Gateway
  def show(conn, %{"id" => id}) do
    with {:ok, gateway} <- Gateways.fetch_gateway_by_id(id, conn.assigns.subject) do
      render(conn, :show, gateway: gateway)
    end
  end

  # Create a new Gateway Token
  def create(conn, %{"gateway_group_id" => gateway_group_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(gateway_group_id, subject),
         {:ok, _raw_gateway_token, encoded_token} <-
           Gateways.create_token(gateway_group, %{}, subject) do
      conn
      |> put_status(:created)
      |> render(:token, gateway_token: encoded_token)
    end
  end

  # Delete a Gateway
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Gateways.fetch_gateway_by_id(id, subject),
         {:ok, gateway} <- Gateways.delete_gateway(gateway, subject) do
      render(conn, :show, gateway: gateway)
    end
  end
end
