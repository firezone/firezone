defmodule PortalAPI.MCP.Tool do
  @moduledoc """
  One MCP tool, derived from a single REST operation.

  Carries both the client-facing definition (`name`, `description`,
  `input_schema`, `annotations`) and everything `PortalAPI.MCP.Dispatch` needs
  to turn a `tools/call` into the equivalent request against
  `PortalAPI.Router`.

  `entity` is the `Portal.Scope` entity the underlying operation is scoped by,
  resolved once when the table is built rather than per request.

  `response_fields` lists the record fields a read tool can narrow its
  response to with the `fields` argument, and is `nil` for every other tool.

  `variants` is set on a tool that stands for one operation per posture
  provider type. It maps each type to that type's tool and to the name each
  argument has there.
  """

  @enforce_keys [:name, :method, :path_template, :input_schema]
  defstruct [
    :name,
    :title,
    :description,
    :method,
    :path_template,
    :input_schema,
    :annotations,
    :controller,
    :action,
    :route,
    path_params: [],
    query_params: [],
    body_params: [],
    response_fields: nil,
    variants: nil,
    write?: false,
    entity: nil
  ]

  @type t :: %__MODULE__{}

  @doc """
  Renders the tool as the JSON object returned by `tools/list`.
  """
  def to_definition(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.input_schema,
      annotations: tool.annotations
    }
  end
end
