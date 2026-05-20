defmodule PortalAPI.ClientTokenController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.Authentication
  alias PortalAPI.Error
  alias PortalAPI.Pagination
  alias __MODULE__.Database

  tags ["Client Tokens"]

  operation :index,
    summary: "List Client Tokens for a Service Account or User Actor",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Client Tokens returned", type: :integer],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Client Token List Response", "application/json", PortalAPI.Schemas.ClientToken.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"actor_id" => actor_id} = params) do
    subject = conn.assigns.subject
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actor} <- Database.fetch_actor(actor_id, subject),
         :ok <- revocable_actor?(actor),
         {:ok, tokens, metadata} <- Database.list_tokens(actor, subject, list_opts) do
      render(conn, :index, tokens: tokens, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :create,
    summary: "Create a Client Token for a Service Account",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Client Token Attributes", "application/json", PortalAPI.Schemas.ClientToken.Request,
       required: true},
    responses: [
      ok: {"Client Token Response", "application/json", PortalAPI.Schemas.ClientToken.Response}
    ]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"actor_id" => actor_id, "client_token" => attrs}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Database.fetch_actor(actor_id, subject),
         :ok <- service_account_actor?(actor),
         {:ok, token} <- Authentication.create_headless_client_token(actor, attrs, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Authentication.encode_fragment!(token))
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, %{"actor_id" => _actor_id}) do
    changeset =
      {%{}, %{client_token: :map}}
      |> Ecto.Changeset.cast(%{}, [:client_token])
      |> Ecto.Changeset.validate_required([:client_token])

    Error.handle(conn, {:error, changeset})
  end

  operation :delete,
    summary: "Delete a Client Token",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Client Token ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Deleted Client Token Response", "application/json", PortalAPI.Schemas.ClientToken.DeletedResponse}
    ]

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"actor_id" => actor_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Database.fetch_actor(actor_id, subject),
         :ok <- revocable_actor?(actor),
         {:ok, token} <- Database.delete_token_by_id(token_id, actor, subject) do
      render(conn, :deleted, token: token)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :delete_all,
    summary: "Delete all Client Tokens for a Service Account or User Actor",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Deleted Client Tokens Response", "application/json",
         PortalAPI.Schemas.ClientToken.DeletedAllResponse}
    ]

  @spec delete_all(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_all(conn, %{"actor_id" => actor_id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Database.fetch_actor(actor_id, subject),
         :ok <- revocable_actor?(actor),
         {deleted_count, _} <- Database.delete_all_tokens(actor, subject) do
      render(conn, :deleted_all, count: deleted_count)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp service_account_actor?(%Portal.Actor{type: :service_account}), do: :ok

  defp service_account_actor?(_actor) do
    {:error, :bad_request, reason: "Actor must be a service account"}
  end

  defp revocable_actor?(%Portal.Actor{type: type})
       when type in [:service_account, :account_user, :account_admin_user],
       do: :ok

  defp revocable_actor?(_actor) do
    {:error, :bad_request, reason: "Actor must be a service account or user actor"}
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Actor
    alias Portal.ClientToken
    alias Portal.Safe

    def fetch_actor(id, subject) do
      result =
        from(a in Actor, where: a.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    end

    def list_tokens(actor, subject, opts \\ []) do
      from(t in ClientToken,
        as: :client_tokens,
        where: t.actor_id == ^actor.id,
        order_by: [desc: t.inserted_at]
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:client_tokens, :desc, :inserted_at},
        {:client_tokens, :desc, :id}
      ]
    end

    def delete_token_by_id(id, actor, subject) do
      result =
        from(t in ClientToken,
          where: t.id == ^id and t.actor_id == ^actor.id,
          select: %{
            id: t.id,
            actor_id: t.actor_id,
            expires_at: t.expires_at,
            inserted_at: t.inserted_at,
            updated_at: t.updated_at
          }
        )
        |> Safe.scoped(subject)
        |> Safe.delete_all()

      case result do
        {:error, :unauthorized} ->
          {:error, :unauthorized}

        {0, _} ->
          {:error, :not_found}

        {1, [token]} ->
          {:ok, struct(ClientToken, token)}
      end
    end

    def delete_all_tokens(actor, subject) do
      from(t in ClientToken, where: t.actor_id == ^actor.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end
end
