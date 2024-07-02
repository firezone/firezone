defmodule API.IdentityController do
  use API, :controller
  alias API.Pagination
  alias Domain.Auth

  action_fallback API.FallbackController

  # List Identities
  def index(conn, %{"actor_id" => actor_id} = params) do
    subject = conn.assigns.subject
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actor} <- Domain.Actors.fetch_actor_by_id(actor_id, subject),
         {:ok, identities, metadata} <- Auth.list_identities_for(actor, subject, list_opts) do
      render(conn, :index, identities: identities, metadata: metadata)
    end
  end

  # Create an Identity
  def create(conn, %{
        "actor_id" => actor_id,
        "provider_id" => provider_id,
        "identity" => params
      }) do
    subject = conn.assigns.subject

    params =
      Map.put_new(
        params,
        "provider_identifier_confirmation",
        Map.get(params, "provider_identifier")
      )

    with {:ok, actor} <- Domain.Actors.fetch_actor_by_id(actor_id, subject),
         {:ok, provider} <- Auth.fetch_provider_by_id(provider_id, subject),
         true = valid_provider?(provider),
         {:ok, identity} <- Auth.create_identity(actor, provider, params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/actors/#{actor_id}/identities/#{identity.id}")
      |> render(:show, identity: identity)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
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

  defp valid_provider?(provider) do
    Auth.fetch_provider_capabilities!(provider)
    |> Keyword.fetch!(:provisioners)
    |> Enum.member?(:manual)
  end
end
