defmodule API.IdentityProviderController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Auth

  action_fallback API.FallbackController

  tags ["Identity Providers"]

  operation :index,
    summary: "List Identity Providers",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Identity Providers returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok:
        {"Identity Provider Response", "application/json",
         API.Schemas.IdentityProvider.ListResponse}
    ]

  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, identity_providers, metadata} <-
           Auth.list_providers(conn.assigns.subject, list_opts) do
      render(conn, :index, identity_providers: identity_providers, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Identity Provider",
    parameters: [
      id: [
        in: :path,
        description: "Identity Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Identity Provider Response", "application/json", API.Schemas.IdentityProvider.Response}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, identity_provider} <- Auth.fetch_provider_by_id(id, conn.assigns.subject) do
      render(conn, :show, identity_provider: identity_provider)
    end
  end

  operation :delete,
    summary: "Delete a Identity Provider",
    parameters: [
      id: [
        in: :path,
        description: "Identity Provider ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Identity Provider Response", "application/json", API.Schemas.IdentityProvider.Response}
    ]

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, identity_provider} <- Auth.delete_provider_by_id(id, subject) do
      render(conn, :show, identity_provider: identity_provider)
    end
  end
end
