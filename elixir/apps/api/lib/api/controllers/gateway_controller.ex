defmodule API.GatewayController do
  use API, :controller
  alias API.Pagination
  alias Domain.Gateways

  action_fallback API.FallbackController

  # List Gateways
  def index(conn, params) do
    list_opts =
      params
      |> Pagination.params_to_list_opts()
      |> Keyword.put(:preload, :online?)

    with {:ok, gateways, metadata} <- Gateways.list_gateways(conn.assigns.subject, list_opts) do
      render(conn, :index, gateways: gateways, metadata: metadata)
    end
  end

  # Show a specific Gateway
  def show(conn, %{"id" => id}) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, conn.assigns.subject, preload: :online?) do
      render(conn, :show, gateway: gateway)
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
