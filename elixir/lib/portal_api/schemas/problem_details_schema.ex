defmodule PortalAPI.Schemas.ProblemDetails do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @content_type "application/problem+json"

  @response_details %{
    bad_request: "The request could not be processed.",
    unauthorized: "Authentication credentials were missing or invalid.",
    forbidden: "You do not have permission to perform this action.",
    not_found: "The requested resource could not be found.",
    conflict: "The request conflicts with the current state of the resource.",
    unprocessable_entity: "The request body failed validation.",
    too_many_requests:
      "Rate limit exceeded. Retry after the time indicated in the Retry-After header."
  }

  OpenApiSpex.schema(%{
    title: "ProblemDetails",
    description: "RFC 9457 (Problem Details for HTTP APIs) error response.",
    type: :object,
    properties: %{
      type: %Schema{
        type: :string,
        description: "URI identifying the problem type. Always \"about:blank\" for now.",
        example: "about:blank"
      },
      title: %Schema{
        type: :string,
        description:
          "Short, human-readable summary of the problem type (the HTTP status phrase).",
        example: "Not Found"
      },
      status: %Schema{
        type: :integer,
        description: "HTTP status code.",
        example: 404
      },
      detail: %Schema{
        type: :string,
        description: "Human-readable explanation specific to this occurrence of the problem.",
        example: "The requested resource could not be found."
      }
    },
    required: [:type, :title, :status]
  })

  defmodule ValidationErrors do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ValidationErrors",
      description:
        "Map of field name to its errors: a list of messages, or the errors of a nested " <>
          "object or list of objects under the same shape.",
      type: :object,
      additionalProperties: %Schema{
        anyOf: [
          %Schema{type: :array, items: %Schema{type: :string}},
          %Schema{type: :array, items: PortalAPI.Schemas.ProblemDetails.ValidationErrors},
          PortalAPI.Schemas.ProblemDetails.ValidationErrors
        ]
      },
      example: %{"name" => ["can't be blank"]}
    })
  end

  defmodule ValidationError do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ValidationProblemDetails",
      description:
        "RFC 9457 error response for request validation failures. The `validation_errors` " <>
          "member maps each invalid field to a list of human-readable messages. Errors on " <>
          "nested objects and on the items of a list are reported under the same shape, " <>
          "keyed by field name or list index. It is omitted when the failure is not " <>
          "attributable to individual fields.",
      type: :object,
      properties: %{
        type: %Schema{type: :string, example: "about:blank"},
        title: %Schema{type: :string, example: "Unprocessable Content"},
        status: %Schema{type: :integer, example: 422},
        detail: %Schema{type: :string, example: "The request body failed validation."},
        validation_errors: PortalAPI.Schemas.ProblemDetails.ValidationErrors
      },
      required: [:type, :title, :status]
    })
  end

  # Every API route runs the auth, rate-limit, scope, body parsing, and path
  # parameter plugs before the controller, so any operation can produce these.
  @pipeline_codes [:bad_request, :unauthorized, :forbidden, :too_many_requests]

  @doc """
  Builds the `responses` entries for the given error status atoms, for use in
  OpenApiSpex `operation` specs, e.g.

      responses: [ok: {...}] ++ ProblemDetails.responses([:not_found])

  The responses every route in the API pipeline can produce are always
  included, so callers only list the ones specific to their operation.
  """
  def responses(codes) when is_list(codes) do
    Enum.map(Enum.uniq(@pipeline_codes ++ codes), fn code -> {code, response_for(code)} end)
  end

  defp response_for(code) do
    status = Plug.Conn.Status.code(code)
    title = Plug.Conn.Status.reason_phrase(status)
    detail = Map.fetch!(@response_details, code)

    example = %{
      "type" => "about:blank",
      "title" => title,
      "status" => status,
      "detail" => detail
    }

    example =
      if code == :unprocessable_entity do
        Map.put(example, "validation_errors", %{"name" => ["can't be blank"]})
      else
        example
      end

    {title, @content_type, response_schema(code), example: example}
  end

  defp response_schema(:unprocessable_entity), do: ValidationError
  defp response_schema(_code), do: __MODULE__
end
