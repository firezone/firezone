defmodule Web.ScimController do
  use Web, :controller

  def index(conn, _params) do
    conn
    # https://www.iana.org/assignments/media-types/application/scim+json
    |> put_resp_content_type("application/scim+json")
    # TODO: Should we even respond at the SCIM root endpoint?
    |> send_resp(
      200,
      Jason.encode!(%{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
        "totalResults" => 1,
        "Resources" => [
          %{
            "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
            "id" => "1234567890",
            "userName" => "jamil@foo.dev"
          }
        ]
      })
    )
  end
end
