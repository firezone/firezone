defmodule PortalAPI.PolicyController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["Policies"]

  operation :index,
    summary: "List Policies",
    parameters: [
      limit: [in: :query, description: "Limit Policies returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Policy Response", "application/json", PortalAPI.Schemas.Policy.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, policies, metadata} <- Database.list_policies(conn.assigns.subject, list_opts) do
      render(conn, :index, policies: policies, metadata: metadata)
    else
      error -> Error.handle(conn, error)
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
      ok: {"Policy Response", "application/json", PortalAPI.Schemas.Policy.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, policy} <- Database.fetch_policy(id, conn.assigns.subject) do
      render(conn, :show, policy: policy)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :create,
    summary: "Create Policy",
    parameters: [],
    request_body:
      {"Policy Attributes", "application/json", PortalAPI.Schemas.Policy.Request, required: true},
    responses: [
      ok: {"Policy Response", "application/json", PortalAPI.Schemas.Policy.Response}
    ]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"policy" => params}) do
    subject = conn.assigns.subject

    with :ok <- Database.validate_internet_resource_policy(params, subject),
         {:ok, policy} <- Database.create_policy(params, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/policies/#{policy}")
      |> render(:show, policy: policy)
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
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
      {"Policy Attributes", "application/json", PortalAPI.Schemas.Policy.Request, required: true},
    responses: [
      ok: {"Policy Response", "application/json", PortalAPI.Schemas.Policy.Response}
    ]

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "policy" => params}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Database.fetch_policy(id, subject),
         :ok <- Database.validate_internet_resource_policy(params, subject),
         {:ok, policy} <- Database.update_policy(policy, params, subject) do
      render(conn, :show, policy: policy)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
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
      ok: {"Policy Response", "application/json", PortalAPI.Schemas.Policy.Response}
    ]

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, policy} <- Database.fetch_policy(id, subject),
         {:ok, policy} <- Database.delete_policy(policy, subject) do
      render(conn, :show, policy: policy)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Policy, Safe, Auth}

    def list_policies(subject, opts \\ []) do
      from(p in Policy, as: :policies)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_policy(id, subject) do
      result =
        from(p in Policy, where: p.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        policy -> {:ok, policy}
      end
    end

    def update_policy(policy, attrs, subject) do
      policy
      |> changeset(attrs)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def validate_internet_resource_policy(attrs, %Authentication.Subject{} = subject) do
      resource_id = attrs["resource_id"]

      if resource_id do
        resource =
          from(r in Portal.Resource, where: r.id == ^resource_id)
          |> Safe.scoped(subject)
          |> Safe.one()

        case resource do
          nil ->
            {:error, :not_found}

          %{type: :internet} ->
            if Portal.Account.internet_resource_enabled?(subject.account) do
              :ok
            else
              {:error, :forbidden, reason: "Internet resource is not enabled for this account"}
            end

          _ ->
            :ok
        end
      else
        :ok
      end
    end

    def create_policy(attrs, %Authentication.Subject{} = subject) do
      changeset = create_changeset(attrs, subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    def delete_policy(policy, subject) do
      policy
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    defp create_changeset(attrs, %Authentication.Subject{} = subject) do
      %Policy{}
      |> cast(attrs, ~w[description group_id resource_id]a)
      |> validate_required(~w[group_id resource_id]a)
      |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
      |> Policy.changeset()
      |> put_change(:account_id, subject.account.id)
    end

    defp changeset(%Policy{} = policy, attrs) do
      policy
      |> cast(attrs, ~w[description group_id resource_id]a)
      |> validate_required(~w[group_id resource_id]a)
      |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
      |> Policy.changeset()
    end

    def cursor_fields do
      [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]
    end
  end
end
