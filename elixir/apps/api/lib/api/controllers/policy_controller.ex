defmodule API.PolicyController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Policies

  action_fallback API.FallbackController

  tags ["Policies"]

  operation :index,
    summary: "List Policies",
    parameters: [
      limit: [in: :query, description: "Limit Policies returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.ListResponse}
    ]

  # List Policies
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, policies, metadata} <- Policies.list_policies(conn.assigns.subject, list_opts) do
      render(conn, :index, policies: policies, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Policy",
    parameters: [
      id: [
        in: :path,
        description: "Policy ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response}
    ]

  # Show a specific Policy
  def show(conn, %{"id" => id}) do
    with {:ok, policy} <- Policies.fetch_policy_by_id_or_persistent_id(id, conn.assigns.subject) do
      render(conn, :show, policy: policy)
    end
  end

  operation :create,
    summary: "Create Policy",
    parameters: [],
    request_body:
      {"Policy Attributes", "application/json", API.Schemas.Policy.Request, required: true},
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response}
    ]

  # Create a new Policy
  def create(conn, %{"policy" => params}) do
    with {:ok, policy} <- Policies.create_policy(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/policies/#{policy}")
      |> render(:show, policy: policy)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update,
    summary: "Update a Policy",
    parameters: [
      id: [
        in: :path,
        description: "Policy ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Policy Attributes", "application/json", API.Schemas.Policy.Request, required: true},
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response}
    ]

  # Update a Policy
  def update(conn, %{"id" => id, "policy" => params}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id_or_persistent_id(id, subject) do
      case Policies.update_or_replace_policy(policy, params, subject) do
        {:updated, updated_policy} ->
          render(conn, :show, policy: updated_policy)

        {:replaced, _replaced_policy, replacement_policy} ->
          render(conn, :show, policy: replacement_policy)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation :delete,
    summary: "Delete a Policy",
    parameters: [
      id: [
        in: :path,
        description: "Policy ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response}
    ]

  # Delete a Policy
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id_or_persistent_id(id, subject),
         {:ok, policy} <- Policies.delete_policy(policy, subject) do
      render(conn, :show, policy: policy)
    end
  end
end
