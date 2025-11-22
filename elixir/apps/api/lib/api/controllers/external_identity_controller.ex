defmodule API.ExternalIdentityController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{ExternalIdentity, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["ExternalIdentities"]

  operation :index,
    summary: "List External Identities for an Actor",
    parameters: [
      actor_id: [in: :path, description: "Actor ID", type: :string]
    ],
    responses: [
      ok:
        {"ExternalIdentity List Response", "application/json",
         API.Schemas.ExternalIdentity.ListResponse}
    ]

  # List External Identities
  def index(conn, %{"actor_id" => actor_id}) do
    external_identities =
      from(ei in ExternalIdentity,
        where: ei.actor_id == ^actor_id,
        order_by: [desc: ei.inserted_at]
      )
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, external_identities: external_identities)
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
      ok: {"ExternalIdentity Response", "application/json", API.Schemas.ExternalIdentity.Response}
    ]

  # Show a specific External Identity
  def show(conn, %{"id" => id}) do
    external_identity =
      from(ei in ExternalIdentity, where: ei.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, external_identity: external_identity)
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
      ok: {"ExternalIdentity Response", "application/json", API.Schemas.ExternalIdentity.Response}
    ]

  # Delete an External Identity
  def delete(conn, %{"id" => id}) do
    external_identity =
      from(ei in ExternalIdentity, where: ei.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    {:ok, deleted_external_identity} =
      external_identity |> Safe.scoped(conn.assigns.subject) |> Safe.delete()

    render(conn, :show, external_identity: deleted_external_identity)
  end
end
