defmodule PortalAPI.PostureFieldController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.Policies.Postures.Fields
  alias PortalAPI.Schemas.ProblemDetails

  tags ["Policies"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Posture Fields",
    description:
      "Lists every field a Policy's `postures` expression can test, with its type, " <>
        "operators, and platforms. Filter by `provider` to keep the response small.\n\n" <>
        PortalAPI.Schemas.Policy.PostureNode.grammar(),
    parameters: [
      provider: [
        in: :query,
        description: "Filter to the fields of this provider",
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: Enum.map(Fields.providers(), &Atom.to_string/1)
        }
      ]
    ],
    responses:
      [ok: {"Posture Field Response", "application/json", PortalAPI.Schemas.PostureField.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    fields =
      for {provider, fields} <- Enum.sort(Fields.registry()),
          provider_matches?(provider, params["provider"]),
          {field, type} <- Enum.sort(fields) do
        %{
          field: "#{provider}.#{field}",
          provider: provider,
          type: type,
          operators: Fields.operators(type),
          platforms: Fields.platforms(provider, field),
          rows_supported: provider != :firezone
        }
      end

    json(conn, %{data: fields})
  end

  defp provider_matches?(_provider, nil), do: true
  defp provider_matches?(provider, name), do: Atom.to_string(provider) == name
end
