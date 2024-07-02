defmodule API.PolicyController do
  alias Domain.Policies
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Policies
  def index(conn, params) do
    list_opts = params_to_list_opts(params)

    with {:ok, policies, metadata} <- Policies.list_policies(conn.assigns.subject, list_opts) do
      render(conn, :index, policies: policies, metadata: metadata)
    end
  end

  # Show a specific Policy
  def show(conn, %{"id" => id}) do
    with {:ok, policy} <- Policies.fetch_policy_by_id(id, conn.assigns.subject) do
      render(conn, :show, policy: policy)
    end
  end

  # Create a new Policy
  def create(conn, %{"policy" => params}) do
    with {:ok, policy} <- Policies.create_policy(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/policies/#{policy}")
      |> render(:show, policy: policy)
    end
  end

  # Update a Policy
  def update(conn, %{"id" => id, "policy" => params}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id(id, subject),
         {:ok, policy} <- Policies.update_policy(policy, params, subject) do
      render(conn, :show, policy: policy)
    end
  end

  # Delete a Policy
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id(id, subject),
         {:ok, policy} <- Policies.delete_policy(policy, subject) do
      render(conn, :show, policy: policy)
    end
  end
end
