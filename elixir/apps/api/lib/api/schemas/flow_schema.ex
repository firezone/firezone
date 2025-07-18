defmodule API.Schemas.Flow do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Flow",
      description: "Flow",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Flow ID"},
        policy_id: %Schema{type: :string, description: "Policy ID"},
        client_id: %Schema{type: :string, description: "Client ID"},
        gateway_id: %Schema{type: :string, description: "Gateway ID"},
        resource_id: %Schema{type: :string, description: "Resource ID"},
        token_id: %Schema{type: :string, description: "Token ID"},
        inserted_at: %Schema{
          type: :string,
          description: "Flow create timestamp"
        }
      },
      required: [
        :id,
        :policy_id,
        :client_id,
        :gateway_id,
        :resource_id,
        :token_id,
        :inserted_at
      ],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "policy_id" => "bc158ccd-e282-41a0-bc6a-ce7656c4f688",
        "client_id" => "33d7768b-5092-470c-afe5-92fcdbcdaf29",
        "gateway_id" => "cc989653-9ee0-4e27-9821-4e20c0ffcc8a",
        "resource_id" => "85f6db30-c729-411c-a996-b38dd7692888",
        "token_id" => "bbacf5b0-6b75-40db-9aae-36e667a74bfe",
        "inserted_at" => "2025-01-01T00:00:00Z"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Flow

    OpenApiSpex.schema(%{
      title: "FlowResponse",
      description: "Response schema for single Flow",
      type: :object,
      properties: %{
        data: Flow.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "policy_id" => "bc158ccd-e282-41a0-bc6a-ce7656c4f688",
          "client_id" => "33d7768b-5092-470c-afe5-92fcdbcdaf29",
          "gateway_id" => "cc989653-9ee0-4e27-9821-4e20c0ffcc8a",
          "resource_id" => "85f6db30-c729-411c-a996-b38dd7692888",
          "token_id" => "bbacf5b0-6b75-40db-9aae-36e667a74bfe",
          "inserted_at" => "2025-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Flow

    OpenApiSpex.schema(%{
      title: "FlowListResponse",
      description: "Response schema for multiple Flows",
      type: :object,
      properties: %{
        data: %Schema{description: "Flow details", type: :array, items: Flow.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "policy_id" => "bc158ccd-e282-41a0-bc6a-ce7656c4f688",
            "client_id" => "33d7768b-5092-470c-afe5-92fcdbcdaf29",
            "gateway_id" => "cc989653-9ee0-4e27-9821-4e20c0ffcc8a",
            "resource_id" => "85f6db30-c729-411c-a996-b38dd7692888",
            "token_id" => "bbacf5b0-6b75-40db-9aae-36e667a74bfe",
            "inserted_at" => "2025-01-01T00:00:00Z"
          },
          %{
            "id" => "14007d18-14be-4d43-b136-caaa07beb385",
            "policy_id" => "c5999cd5-2b3d-4e88-b58d-93dce5ee87a0",
            "client_id" => "f0f6151b-c239-4487-804e-7e81720845a3",
            "gateway_id" => "024db903-a1da-4685-8ea5-19097f9e2700",
            "resource_id" => "a747525c-870c-4a2f-9e35-a84a5e9fd364",
            "token_id" => "a747525c-870c-4a2f-9e35-a84a5e9fd364",
            "inserted_at" => "2025-01-01T00:00:00Z"
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
