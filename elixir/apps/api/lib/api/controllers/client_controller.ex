defmodule API.ClientController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Clients
  alias OpenApiSpex.Reference

  action_fallback(API.FallbackController)

  tags(["Clients"])

  operation(:index,
    summary: "List Clients",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Clients returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.ListResponse},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # List Clients
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts <- Keyword.put(list_opts, :preload, :online?),
         {:ok, clients, metadata} <- Clients.list_clients(conn.assigns.subject, list_opts) do
      render(conn, :index, clients: clients, metadata: metadata)
    end
  end

  operation(:show,
    summary: "Show Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # Show a specific Client
  def show(conn, %{"id" => id}) do
    with {:ok, client} <-
           Clients.fetch_client_by_id(id, conn.assigns.subject, preload: :online?) do
      render(conn, :show, client: client)
    end
  end

  operation(:update,
    summary: "Update Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Client Attributes", "application/json", API.Schemas.Client.Request, required: true},
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # Update a Client
  def update(conn, %{"id" => id, "client" => params}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Clients.fetch_client_by_id(id, subject, preload: :online?),
         {:ok, client} <- Clients.update_client(client, params, subject) do
      render(conn, :show, client: client)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation(:verify,
    summary: "Verify Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # Verify a Client
  def verify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Clients.fetch_client_by_id(id, subject, preload: :online?),
         {:ok, client} <- Clients.verify_client(client, subject) do
      render(conn, :show, client: client)
    end
  end

  operation(:unverify,
    summary: "Unverify Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # Unverify a Client
  def unverify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Clients.fetch_client_by_id(id, subject, preload: :online?),
         {:ok, client} <- Clients.remove_client_verification(client, subject) do
      render(conn, :show, client: client)
    end
  end

  operation(:delete,
    summary: "Delete a Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response},
      unauthorized: %Reference{"$ref": "#/components/responses/JSONError"},
      not_found: %Reference{"$ref": "#/components/responses/JSONError"}
    ]
  )

  # Delete a Client
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Clients.fetch_client_by_id(id, subject, preload: :online?),
         {:ok, client} <- Clients.delete_client(client, subject) do
      render(conn, :show, client: client)
    end
  end
end
