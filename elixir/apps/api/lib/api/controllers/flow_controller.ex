defmodule API.FlowController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Flows

  action_fallback API.FallbackController

  operation :index,
    tags: ["Flows"],
    summary: "List Flows",
    parameters: [
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index(conn, params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows(conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :index_for_policy,
    tags: ["Policies"],
    summary: "List Flows for a policy",
    parameters: [
      policy_id: [
        in: :path,
        description: "Policy ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index_for_policy(conn, %{"policy_id" => policy_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows_for_policy_id(policy_id, conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :index_for_resource,
    tags: ["Resources"],
    summary: "List Flows for a resource",
    parameters: [
      resource_id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index_for_resource(conn, %{"resource_id" => resource_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows_for_resource_id(resource_id, conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :index_for_client,
    tags: ["Clients"],
    summary: "List Flows for a client",
    parameters: [
      client_id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index_for_client(conn, %{"client_id" => client_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows_for_client_id(client_id, conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :index_for_actor,
    tags: ["Actors"],
    summary: "List Flows for an actor",
    parameters: [
      actor_id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index_for_actor(conn, %{"actor_id" => actor_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows_for_actor_id(actor_id, conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :index_for_gateway,
    tags: ["Gateways"],
    summary: "List Flows for a gateway",
    parameters: [
      gateway_group_id: [
        in: :path,
        description: "Gateway Group ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      gateway_id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Flows returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      min_datetime: [
        in: :query,
        description: "Min UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ],
      max_datetime: [
        in: :query,
        description: "Max UTC datetime",
        type: :string,
        example: "2025-01-01T00:00:00Z"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.ListResponse}
    ]

  def index_for_gateway(conn, %{"gateway_id" => gateway_id} = params) do
    list_opts =
      Pagination.params_to_list_opts(params)
      |> time_filter_to_list_opts(params)

    with {:ok, flows, metadata} <-
           Flows.list_flows_for_gateway_id(gateway_id, conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :show,
    tags: ["Flows"],
    summary: "Show Flow",
    parameters: [
      id: [
        in: :path,
        description: "Flow ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Flow Response", "application/json", API.Schemas.Flow.Response}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, flow} <-
           Flows.fetch_flow_by_id(id, conn.assigns.subject) do
      render(conn, :show, flow: flow)
    end
  end

  def cast_time_range(%{"min_datetime" => from, "max_datetime" => to}) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from),
         {:ok, to, 0} <- DateTime.from_iso8601(to) do
      {:ok, %Domain.Repo.Filter.Range{from: from, to: to}}
    else
      _other -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{"max_datetime" => to}) do
    with {:ok, to, 0} <- DateTime.from_iso8601(to) do
      {:ok, %Domain.Repo.Filter.Range{to: to}}
    else
      _other -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{"min_datetime" => from}) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from) do
      {:ok, %Domain.Repo.Filter.Range{from: from}}
    else
      _other -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{}) do
    {:ok, nil}
  end

  def time_filter_to_list_opts(list_opts, params) do
    case cast_time_range(params) do
      {:ok, nil} -> list_opts
      {:ok, value} -> Keyword.put(list_opts, :filter, range: value)
      other -> other
    end
  end
end
