defmodule PortalAPI.ExternalIdentityController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags ["ExternalIdentities"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List External Identities for an Actor",
    parameters: [
      actor_id: [in: :path, description: "Actor ID", type: :string],
      limit: [in: :query, description: "Limit External Identities returned", type: :integer],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok:
        {"ExternalIdentity List Response", "application/json",
         PortalAPI.Schemas.ExternalIdentity.ListResponse}
    ]

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"actor_id" => actor_id} = params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, external_identities, metadata} <-
           Database.list_external_identities(actor_id, conn.assigns.subject, list_opts) do
      render(conn, :index, external_identities: external_identities, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :show,
    summary: "Show External Identity",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "External Identity ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"ExternalIdentity Response", "application/json",
         PortalAPI.Schemas.ExternalIdentity.Response}
    ]

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, external_identity} <- Database.fetch_external_identity(id, conn.assigns.subject) do
      render(conn, :show, external_identity: external_identity)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Delete an External Identity",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "External Identity ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"ExternalIdentity Response", "application/json",
         PortalAPI.Schemas.ExternalIdentity.Response}
    ]

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    with {:ok, external_identity} <- Database.fetch_external_identity(id, conn.assigns.subject),
         {:ok, deleted_external_identity} <-
           Database.delete_external_identity(external_identity, conn.assigns.subject) do
      render(conn, :show, external_identity: deleted_external_identity)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ExternalIdentity
    alias Portal.Safe

    def list_external_identities(actor_id, subject, opts \\ []) do
      from(ei in ExternalIdentity,
        as: :external_identities,
        where: ei.actor_id == ^actor_id,
        order_by: [desc: ei.inserted_at]
      )
      |> join(:left, [external_identities: ei], iss in Portal.ExternalIdentitySyncState,
        on: iss.external_identity_id == ei.id and iss.account_id == ei.account_id,
        as: :sync_state
      )
      |> preload([sync_state: iss], sync_state: iss)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:external_identities, :desc, :inserted_at},
        {:external_identities, :desc, :id}
      ]
    end

    def fetch_external_identity(id, subject) do
      result =
        from(ei in ExternalIdentity, as: :external_identities, where: ei.id == ^id)
        |> join(:left, [external_identities: ei], iss in Portal.ExternalIdentitySyncState,
          on: iss.external_identity_id == ei.id and iss.account_id == ei.account_id,
          as: :sync_state
        )
        |> preload([sync_state: iss], sync_state: iss)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        external_identity -> {:ok, external_identity}
      end
    end

    def delete_external_identity(external_identity, subject) do
      external_identity
      |> Safe.scoped(subject)
      |> Safe.delete()
    end
  end
end
