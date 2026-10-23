defmodule PortalAPI.Schemas.SiteDevice do
  alias OpenApiSpex.Schema

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SiteDeviceCreateRequest",
      description: "POST body for assigning a Device to a Site",
      type: :object,
      properties: %{
        device: %Schema{
          type: :object,
          properties: %{
            id: %Schema{
              example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
              type: :string,
              format: :uuid,
              description: "ID of the Device to assign"
            }
          },
          required: [:id]
        }
      },
      required: [:device]
    })
  end
end
