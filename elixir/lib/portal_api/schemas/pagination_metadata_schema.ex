defmodule PortalAPI.Schemas.PaginationMetadata do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PaginationMetadata",
    description: "Pagination metadata for paginated responses.",
    type: :object,
    properties: %{
      count: %Schema{example: 1, type: :integer, description: "Total number of matching records"},
      limit: %Schema{example: 10, type: :integer, description: "Page size"},
      next_page: %Schema{
        example: nil,
        type: :string,
        nullable: true,
        description: "Cursor to fetch the next page"
      },
      prev_page: %Schema{
        example: nil,
        type: :string,
        nullable: true,
        description: "Cursor to fetch the previous page"
      }
    },
    required: [:count, :limit, :next_page, :prev_page]
  })
end
