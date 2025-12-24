defmodule PortalAPI.ExternalIdentityController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias Portal.{ExternalIdentity, Safe}
  alias __MODULE__.DB
  import Ecto.Query

  action_fallback PortalAPI.FallbackController

  tags ["ExternalIdentities"]

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

  # List External Identities
  def index(conn, %{"actor_id" => actor_id} = params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, external_identities, metadata} <-
           DB.list_external_identities(actor_id, conn.assigns.subject, list_opts) do
      render(conn, :index, external_identities: external_identities, metadata: metadata)
    end
  end

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
      ok: {"ExternalIdentity Response", "application/json", PortalAPI.Schemas.ExternalIdentity.Response}
    ]

  # Show a specific External Identity
  def show(conn, %{"id" => id}) do
    with {:ok, external_identity} <- DB.fetch_external_identity(id, conn.assigns.subject) do
      render(conn, :show, external_identity: external_identity)
    end
  end

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
      ok: {"ExternalIdentity Response", "application/json", PortalAPI.Schemas.ExternalIdentity.Response}
    ]

  # Delete an External Identity
  def delete(conn, %{"id" => id}) do
    with {:ok, external_identity} <- DB.fetch_external_identity(id, conn.assigns.subject),
         {:ok, deleted_external_identity} <-
           DB.delete_external_identity(external_identity, conn.assigns.subject) do
      render(conn, :show, external_identity: deleted_external_identity)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{ExternalIdentity, Safe}

    def list_external_identities(actor_id, subject, opts \\ []) do
      from(ei in ExternalIdentity,
        as: :external_identities,
        where: ei.actor_id == ^actor_id,
        order_by: [desc: ei.inserted_at]
      )
      |> Safe.scoped(subject)
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
        from(ei in ExternalIdentity, where: ei.id == ^id)
        |> Safe.scoped(subject)
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
