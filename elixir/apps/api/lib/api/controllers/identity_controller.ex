defmodule API.IdentityController do
  alias Domain.Auth
  import API.ControllerHelpers
  use API, :controller

  action_fallback API.FallbackController

  # List Identities
  def index(conn, %{"actor_id" => actor_id} = params) do
    subject = conn.assigns.subject
    list_opts = params_to_list_opts(params)

    with {:ok, actor} <- Domain.Actors.fetch_actor_by_id(actor_id, subject),
         {:ok, identities, metadata} <- Auth.list_identities_for(actor, subject, list_opts) do
      render(conn, :index, identities: identities, metadata: metadata)
    end
  end

  # Show a specific Identity
  def show(conn, %{"id" => id}) do
    with {:ok, identity} <- Auth.fetch_identity_by_id(id, conn.assigns.subject) do
      render(conn, :show, identity: identity)
    end
  end

  # Delete an Identity
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, identity} <- Auth.fetch_identity_by_id(id, subject),
         {:ok, identity} <- Auth.delete_identity(identity, subject) do
      render(conn, :show, identity: identity)
    end
  end
end
