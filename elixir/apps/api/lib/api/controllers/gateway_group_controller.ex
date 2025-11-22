defmodule API.GatewayGroupController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.{Gateways, Tokens}
  alias __MODULE__.Query

  action_fallback API.FallbackController

  tags ["Gateway Groups (Sites)"]

  operation :index,
    summary: "List Gateway Groups",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Gateway Groups returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Gateway Group Response", "application/json", API.Schemas.GatewayGroup.ListResponse}
    ]

  # List Gateway Groups / Sites
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, gateway_groups, metadata} <- Query.list_groups(conn.assigns.subject, list_opts) do
      render(conn, :index, gateway_groups: gateway_groups, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Gateway Group",
    parameters: [
      id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Group Response", "application/json", API.Schemas.GatewayGroup.Response}
    ]

  # Show a specific Gateway Group / Site
  def show(conn, %{"id" => id}) do
    gateway_group = Query.fetch_group(conn.assigns.subject, id)
    render(conn, :show, gateway_group: gateway_group)
  end

  operation :create,
    summary: "Create Gateway Group",
    parameters: [],
    request_body:
      {"Gateway Group Attributes", "application/json", API.Schemas.GatewayGroup.Request,
       required: true},
    responses: [
      ok: {"Gateway Group Response", "application/json", API.Schemas.GatewayGroup.Response}
    ]

  # Create a new Gateway Group / Site
  def create(conn, %{"gateway_group" => params}) do
    with {:ok, gateway_group} <- Gateways.create_group(params, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/gateway_groups/#{gateway_group}")
      |> render(:show, gateway_group: gateway_group)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  operation :update,
    summary: "Update a Gateway Group",
    parameters: [
      id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Gateway Group Attributes", "application/json", API.Schemas.GatewayGroup.Request,
       required: true},
    responses: [
      ok: {"Gateway Group Response", "application/json", API.Schemas.GatewayGroup.Response}
    ]

  # Update a Gateway Group / Site
  def update(conn, %{"id" => id, "gateway_group" => params}) do
    subject = conn.assigns.subject
    gateway_group = Query.fetch_group(subject, id)

    with {:ok, gateway_group} <- Query.update_group(gateway_group, params, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation :delete,
    summary: "Delete a Gateway Group",
    parameters: [
      id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Group Response", "application/json", API.Schemas.GatewayGroup.Response}
    ]

  # Delete a Gateway Group / Site
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject
    gateway_group = Query.fetch_group(subject, id)

    with {:ok, gateway_group} <- Query.delete_group(gateway_group, subject) do
      render(conn, :show, gateway_group: gateway_group)
    end
  end

  operation :create_token,
    summary: "Create a Gateway Token",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"New Gateway Token Response", "application/json", API.Schemas.GatewayGroupToken.NewToken}
    ]

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

  operation :delete_token,
    summary: "Delete a Gateway Token",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway Token ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Deleted Gateway Token Response", "application/json",
         API.Schemas.GatewayGroupToken.DeletedToken}
    ]

  # Delete/Revoke a Gateway Group Token
  def delete_token(conn, %{"gateway_group_id" => _gateway_group_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- Tokens.fetch_token_by_id(token_id, subject),
         {:ok, token} <- Tokens.delete_token(token, subject) do
      render(conn, :deleted_token, gateway_token: token)
    end
  end

  operation :delete_all_tokens,
    summary: "Delete all Gateway Tokens for a given Gateway Group",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Deleted Gateway Tokens Response", "application/json",
         API.Schemas.GatewayGroupToken.DeletedTokens}
    ]

  def delete_all_tokens(conn, %{"gateway_group_id" => gateway_group_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway_group} <- Gateways.fetch_group_by_id(gateway_group_id, subject),
         {:ok, deleted_count} <- Tokens.delete_tokens_for(gateway_group, subject) do
      render(conn, :deleted_tokens, %{count: deleted_count})
    end
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.{Gateways, Safe, Repo}

    def list_groups(subject, opts \\ []) do
      from(g in Gateways.Group, as: :groups)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(subject, id) do
      from(g in Gateways.Group, where: g.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_group(group, attrs, subject) do
      group
      |> Repo.preload(:account)
      |> changeset(attrs, subject)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_group(group, subject) do
      group
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    defp changeset(group, attrs, subject) do
      Gateways.Group.Changeset.update(group, attrs, subject)
    end

    def cursor_fields do
      [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]
    end
  end
end
