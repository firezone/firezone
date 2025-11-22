defmodule API.PolicyController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Policies
  alias __MODULE__.DB

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

    with {:ok, policies, metadata} <- DB.list_policies(conn.assigns.subject, list_opts) do
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
    policy = DB.fetch_policy(conn.assigns.subject, id)
    render(conn, :show, policy: policy)
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
    policy = DB.fetch_policy(subject, id)

    with {:ok, policy} <- DB.update_policy(policy, params, subject) do
      render(conn, :show, policy: policy)
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
    policy = DB.fetch_policy(subject, id)

    with {:ok, policy} <- DB.delete_policy(policy, subject) do
      render(conn, :show, policy: policy)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Policies, Safe}

    def list_policies(subject, opts \\ []) do
      from(p in Policies.Policy, as: :policies)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_policy(subject, id) do
      from(p in Policies.Policy, where: p.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_policy(policy, attrs, subject) do
      policy
      |> changeset(attrs)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_policy(policy, subject) do
      policy
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    defp changeset(policy, attrs) do
      Policies.Policy.Changeset.update(policy, attrs)
    end

    def cursor_fields do
      [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]
    end
  end
end
