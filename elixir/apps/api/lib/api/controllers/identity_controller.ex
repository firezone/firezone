defmodule API.IdentityController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias Domain.{Auth, Safe}
  import Ecto.Query

  action_fallback API.FallbackController

  tags ["Identities"]

  operation :index,
    summary: "List Identities for an Actor",
    parameters: [
      actor_id: [in: :path, description: "Actor ID", type: :string]
    ],
    responses: [
      ok: {"Identity List Response", "application/json", API.Schemas.Identity.ListResponse}
    ]

  # List Identities
  def index(conn, %{"actor_id" => actor_id}) do
    identities =
      from(i in Auth.Identity,
        where: i.actor_id == ^actor_id,
        order_by: [desc: i.inserted_at]
      )
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.all()

    render(conn, :index, identities: identities)
  end

  operation :show,
    summary: "Show Identity",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Identity ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Identity Response", "application/json", API.Schemas.Identity.Response}
    ]

  # Show a specific Identity
  def show(conn, %{"id" => id}) do
    identity =
      from(i in Auth.Identity, where: i.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    render(conn, :show, identity: identity)
  end

  operation :delete,
    summary: "Delete an Identity",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Identity ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Identity Response", "application/json", API.Schemas.Identity.Response}
    ]

  # Delete an Identity
  def delete(conn, %{"id" => id}) do
    identity =
      from(i in Auth.Identity, where: i.id == ^id)
      |> Safe.scoped(conn.assigns.subject)
      |> Safe.one!()

    {:ok, deleted_identity} = identity |> Safe.scoped(conn.assigns.subject) |> Safe.delete()
    render(conn, :show, identity: deleted_identity)
  end
end
