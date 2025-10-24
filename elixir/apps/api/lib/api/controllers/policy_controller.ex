defmodule API.PolicyController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Policies
  alias OpenApiSpex.Reference

  action_fallback API.FallbackController

  tags ["Policies"]

  operation :index,
    summary: "List Policies",
    parameters: [
      limit: [in: :query, description: "Limit Policies returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Policy Response", "application/json", API.Schemas.Policy.ListResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # List Policies
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, policies, metadata} <- Policies.list_policies(conn.assigns.subject, list_opts) do
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
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Show a specific Policy
  def show(conn, %{"id" => id}) do
    with {:ok, policy} <- Policies.fetch_policy_by_id(id, conn.assigns.subject) do
      render(conn, :show, policy: policy)
    end
  end

  operation :create,
    summary: "Create Policy",
    parameters: [],
    request_body:
      {"Policy Attributes", "application/json", API.Schemas.Policy.Request, required: true},
    responses: [
      created: {"Policy Response", "application/json", API.Schemas.Policy.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
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
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Update a Policy
  def update(conn, %{"id" => id, "policy" => params}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id(id, subject) do
      case Policies.update_policy(policy, params, subject) do
        {:ok, policy} ->
          render(conn, :show, policy: policy)

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
      ok: {"Policy Response", "application/json", API.Schemas.Policy.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]

  # Delete a Policy
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Policies.fetch_policy_by_id(id, subject),
         {:ok, policy} <- Policies.delete_policy(policy, subject) do
      render(conn, :show, policy: policy)
    end
  end
end
