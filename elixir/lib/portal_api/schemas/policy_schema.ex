defmodule PortalAPI.Schemas.Policy do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Policy",
      description: "Policy",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Policy ID"},
        group_id: %Schema{type: :string, description: "Group ID"},
        resource_id: %Schema{type: :string, description: "Resource ID"},
        description: %Schema{type: :string, description: "Policy Description"}
      },
      required: [:name, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
        "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
        "description" => "Policy to allow something"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyRequest",
      description: "POST body for creating a Policy",
      type: :object,
      properties: %{
        policy: Policy.Schema
      },
      required: [:policy],
      example: %{
        "policy" => %{
          "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
          "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
          "description" => "Policy to allow something"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyResponse",
      description: "Response schema for single Policy",
      type: :object,
      properties: %{
        data: Policy.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
          "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
          "description" => "Policy to allow something"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyListResponse",
      description: "Response schema for multiple Policies",
      type: :object,
      properties: %{
        data: %Schema{description: "Policy details", type: :array, items: Policy.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
            "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
            "description" => "Policy to allow something"
          },
          %{
            "id" => "6301d7d2-4938-4123-87de-282c01cca656",
            "resource_id" => "9876bd25-0f6c-48fb-a9fd-196ba9be86e5",
            "group_id" => "343385a2-5437-4c66-8744-1332421ff736",
            "description" => "Policy to allow something else"
          }
        ],
        "metadata" => %{
          "limit" => 10,
          "total" => 100,
          "prev_page" => "123123425",
          "next_page" => "98776234123"
        }
      }
    })
  end
end
