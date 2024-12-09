defmodule API.IdentityController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Auth

  action_fallback API.FallbackController

  tags ["Identities"]

  operation :index,
    summary: "List Identities for an Actor",
    parameters: [
      actor_id: [in: :path, description: "Actor ID", type: :string],
      limit: [in: :query, description: "Limit Identities returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Identity List Response", "application/json", API.Schemas.Identity.ListResponse}
    ]

  # List Identities
  def index(conn, %{"actor_id" => actor_id} = params) do
    subject = conn.assigns.subject
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actor} <- Domain.Actors.fetch_actor_by_id(actor_id, subject),
         {:ok, identities, metadata} <- Auth.list_identities_for(actor, subject, list_opts) do
      render(conn, :index, identities: identities, metadata: metadata)
    end
  end

  operation :create,
    summary: "Create an Identity for an Actor",
    parameters: [
      actor_id: [in: :path, description: "Actor ID", type: :string],
      provider_id: [in: :path, description: "Provider ID", type: :string]
    ],
    request_body:
      {"Identity Attributes", "application/json", API.Schemas.Identity.Request, required: true},
    responses: [
      ok: {"Identity Response", "application/json", API.Schemas.Identity.Response}
    ]

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
      |> maybe_put_email()
      |> maybe_put_identifier()

    with {:ok, actor} <- Domain.Actors.fetch_actor_by_id(actor_id, subject),
         {:ok, provider} <- Auth.fetch_provider_by_id(provider_id, subject),
         {:provider_check, true} <- valid_provider?(provider),
         {:ok, identity} <- Auth.create_identity(actor, provider, params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actors/#{actor_id}/identities/#{identity.id}")
      |> render(:show, identity: identity)
    else
      {:provider_check, _false} -> {:error, :unprocessable_entity}
      other -> other
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
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
    with {:ok, identity} <- Auth.fetch_identity_by_id(id, conn.assigns.subject) do
      render(conn, :show, identity: identity)
    end
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
    subject = conn.assigns.subject

    with {:ok, identity} <- Auth.fetch_identity_by_id(id, subject),
         {:ok, identity} <- Auth.delete_identity(identity, subject) do
      render(conn, :show, identity: identity)
    end
  end

  defp valid_provider?(provider) do
    valid? =
      Auth.fetch_provider_capabilities!(provider)
      |> Keyword.fetch!(:provisioners)
      |> Enum.member?(:manual)

    {:provider_check, valid?}
  end

  defp maybe_put_email(params) do
    email = params["email"]
    identifier = params["provider_identifier"]

    cond do
      !is_nil(email) && valid_email?(email) ->
        params

      !is_nil(identifier) && valid_email?(identifier) ->
        Map.put(params, "email", String.trim(identifier))

      true ->
        params
    end
  end

  defp maybe_put_identifier(params) do
    email = params["email"]
    identifier = params["provider_identifier"]

    cond do
      !is_nil(identifier) && String.trim(identifier) != "" ->
        params

      !is_nil(email) && valid_email?(email) ->
        Map.put(params, "provider_identifier", String.trim(email))
        |> Map.put("provider_identifier_confirmation", String.trim(email))

      true ->
        params
    end
  end

  defp valid_email?(str) do
    String.trim(str) =~ ~r/^[^\s]+@[^\s]+\.[^\s]+$/
  end
end
