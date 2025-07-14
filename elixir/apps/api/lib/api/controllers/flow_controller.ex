defmodule API.FlowController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Flows

  action_fallback API.FallbackController

  tags ["Flows"]

  operation :index,
    summary: "List Flows",
    parameters: [
      policy_id: [
        in: :query,
        description: "Policy ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      resource_id: [
        in: :query,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      client_id: [
        in: :query,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      actor_id: [
        in: :query,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      gateway_id: [
        in: :query,
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

  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, list_opts} <- time_filter_to_list_opts(list_opts, params),
         {:ok, list_opts} <- flows_params_to_list_opts(list_opts, params),
         {:ok, flows, metadata} <- Flows.list_flows(conn.assigns.subject, list_opts) do
      render(conn, :index, flows: flows, metadata: metadata)
    end
  end

  operation :show,
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
      {:error, _reason} -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{"max_datetime" => to}) do
    with {:ok, to, 0} <- DateTime.from_iso8601(to) do
      {:ok, %Domain.Repo.Filter.Range{to: to}}
    else
      {:error, _reason} -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{"min_datetime" => from}) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from) do
      {:ok, %Domain.Repo.Filter.Range{from: from}}
    else
      {:error, _reason} -> {:error, :bad_request}
    end
  end

  def cast_time_range(%{}) do
    {:ok, nil}
  end

  def time_filter_to_list_opts(list_opts, params) do
    case cast_time_range(params) do
      {:ok, nil} -> {:ok, list_opts}
      {:ok, value} -> {:ok, Keyword.put(list_opts, :filter, range: value)}
      other -> other
    end
  end

  def flows_params_to_list_opts(list_opts, params, filter_name, param_name) do
    if param = params[param_name] do
      Keyword.update(list_opts, :filter, [{filter_name, param}], fn filter ->
        filter ++ [{filter_name, param}]
      end)
    else
      list_opts
    end
  end

  def flows_params_to_list_opts(list_opts, params) do
    {:ok,
     list_opts
     |> flows_params_to_list_opts(params, :policy_id, "policy_id")
     |> flows_params_to_list_opts(params, :resource_id, "resource_id")
     |> flows_params_to_list_opts(params, :client_id, "client_id")
     |> flows_params_to_list_opts(params, :actor_id, "actor_id")
     |> flows_params_to_list_opts(params, :gateway_id, "gateway_id")}
  end
end
