defmodule API.GatewayController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Gateways
  alias __MODULE__.Query

  action_fallback API.FallbackController

  tags ["Gateways"]

  operation :index,
    summary: "List Gateways",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Gateways returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", API.Schemas.Gateway.ListResponse}
    ]

  # List Gateways
  def index(conn, params) do
    list_opts =
      params
      |> Pagination.params_to_list_opts()
      |> Keyword.put(:preload, :online?)

    list_opts =
      if group_id = params["gateway_group_id"] do
        Keyword.put(list_opts, :filter, gateway_group_id: group_id)
      else
        list_opts
      end

    with {:ok, gateways, metadata} <- Query.list_gateways(conn.assigns.subject, list_opts) do
      render(conn, :index, gateways: gateways, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Gateway",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", API.Schemas.Gateway.Response}
    ]

  # Show a specific Gateway
  def show(conn, %{"id" => id}) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, conn.assigns.subject, preload: :online?) do
      render(conn, :show, gateway: gateway)
    end
  end

  operation :delete,
    summary: "Delete a Gateway",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", API.Schemas.Gateway.Response}
    ]

  # Delete a Gateway
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Gateways.fetch_gateway_by_id(id, subject, preload: :online?),
         {:ok, gateway} <- Gateways.delete_gateway(gateway, subject) do
      render(conn, :show, gateway: gateway)
    end
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.{Gateways, Safe}

    def list_gateways(subject, opts \\ []) do
      from(g in Gateways.Gateway, as: :gateways)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:gateways, :asc, :inserted_at},
        {:gateways, :asc, :id}
      ]
    end
  end
end
