defmodule PortalAPI.Schemas.ProblemDetails do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @content_type "application/problem+json"

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
        description: "Short, human-readable summary of the problem type (the HTTP status phrase).",
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
    required: [:type, :title, :status],
    example: %{
      "type" => "about:blank",
      "title" => "Not Found",
      "status" => 404,
      "detail" => "The requested resource could not be found."
    }
  })

  defmodule ValidationError do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ValidationProblemDetails",
      description:
        "RFC 9457 error response for request validation failures. The `validation_errors` " <>
          "member maps each invalid field to a list of human-readable messages.",
      type: :object,
      properties: %{
        type: %Schema{type: :string, example: "about:blank"},
        title: %Schema{type: :string, example: "Unprocessable Content"},
        status: %Schema{type: :integer, example: 422},
        detail: %Schema{type: :string, example: "The request body failed validation."},
        validation_errors: %Schema{
          type: :object,
          description: "Map of field name to a list of validation error messages.",
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      },
      required: [:type, :title, :status, :validation_errors],
      example: %{
        "type" => "about:blank",
        "title" => "Unprocessable Content",
        "status" => 422,
        "detail" => "The request body failed validation.",
        "validation_errors" => %{"name" => ["can't be blank"]}
      }
    })
  end

  @doc """
  Builds the `responses` entries for the given error status atoms, for use in
  OpenApiSpex `operation` specs, e.g.

      responses: [ok: {...}] ++ ProblemDetails.responses([:unauthorized, :not_found])
  """
  def responses(codes) when is_list(codes) do
    Enum.map(codes, fn code -> {code, response_for(code)} end)
  end

  defp response_for(:bad_request),
    do: {"Bad Request", @content_type, __MODULE__}

  defp response_for(:unauthorized),
    do: {"Unauthorized", @content_type, __MODULE__}

  defp response_for(:forbidden),
    do: {"Forbidden", @content_type, __MODULE__}

  defp response_for(:not_found),
    do: {"Not Found", @content_type, __MODULE__}

  defp response_for(:conflict),
    do: {"Conflict", @content_type, __MODULE__}

  defp response_for(:unprocessable_entity),
    do: {"Unprocessable Content", @content_type, ValidationError}

  defp response_for(:too_many_requests),
    do: {"Too Many Requests", @content_type, __MODULE__}
end
