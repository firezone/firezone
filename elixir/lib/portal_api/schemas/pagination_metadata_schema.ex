defmodule PortalAPI.Schemas.PaginationMetadata do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PaginationMetadata",
    description: "Pagination metadata for paginated responses.",
    type: :object,
    properties: %{
      count: %Schema{type: :integer, description: "Total number of matching records"},
      limit: %Schema{type: :integer, description: "Page size"},
      next_page: %Schema{
        type: :string,
        nullable: true,
        description: "Cursor to fetch the next page"
      },
      prev_page: %Schema{
        type: :string,
        nullable: true,
        description: "Cursor to fetch the previous page"
      }
    },
    required: [:count, :limit, :next_page, :prev_page],
    example: %{
      "limit" => 10,
      "count" => 1,
      "prev_page" => nil,
      "next_page" => nil
    }
  })
end
