defmodule API.GatewayGroupController do
  use API, :controller
  alias API.Pagination
  alias Domain.{Gateways, Tokens}

  action_fallback API.FallbackController

  # List Gateway Groups / Sites
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

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

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  # Update a Gateway Group / Site
  def update(conn, %{"id" => id, "gateway_group" => params}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(id, subject),
         {:ok, gateway_group} <- Gateways.update_group(gateway_group, params, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  # Delete a Gateway Group / Site
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(id, subject),
         {:ok, gateway_group} <- Gateways.delete_group(gateway_group, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  # Create a Gateway Group Token (used for deploying a gateway)
  def create_token(conn, %{"gateway_group_id" => gateway_group_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(gateway_group_id, subject),
         {:ok, gateway_token, encoded_token} <-
           Gateways.create_token(gateway_group, %{}, subject) do
      conn
      |> put_status(:created)
      |> render(:token, gateway_token: gateway_token, encoded_token: encoded_token)
    end
  end

  # Delete/Revoke a Gateway Group Token
  def delete_token(conn, %{"gateway_group_id" => _gateway_group_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- Tokens.fetch_token_by_id(token_id, subject),
         {:ok, token} <- Tokens.delete_token(token, subject) do
      render(conn, :deleted_token, gateway_token: token)
    end
  end

  def delete_all_tokens(conn, %{"gateway_group_id" => gateway_group_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(gateway_group_id, subject),
         {:ok, deleted_tokens} <- Tokens.delete_tokens_for(gateway_group, subject) do
      render(conn, :deleted_tokens, %{tokens: deleted_tokens})
    end
  end
end
