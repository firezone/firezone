defmodule PortalAPI.MCP.Tool do
  @moduledoc """
  One MCP tool, derived from a single REST operation.

  Carries both the client-facing definition (`name`, `description`,
  `input_schema`, `annotations`) and everything `PortalAPI.MCP.Dispatch` needs
  to turn a `tools/call` into the equivalent request against
  `PortalAPI.Router`.
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
    path_params: [],
    query_params: [],
    body_params: [],
    write?: false
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
