defmodule PortalWeb.AvatarController do
  use PortalWeb, :controller
  alias __MODULE__.Database

  # The URL carries the photo's version, so a browser can keep it for good.
  @cache_control "private, max-age=31536000, immutable"

  # The body only goes out once its bytes match a JPEG or PNG signature, and
  # the content type is one of those two.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  def show(conn, %{"id" => id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Portal.ExternalIdentity{} = identity <- Database.get_identity(id, conn.assigns.subject),
         {:ok, body, content_type} <- Portal.Avatars.fetch(identity) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'")
      |> send_resp(200, body)
    else
      _other -> send_resp(conn, 404, "")
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ExternalIdentity
    alias Portal.Safe

    def get_identity(id, subject) do
      from(i in ExternalIdentity, where: i.id == ^id and not is_nil(i.avatar_etag))
      |> Safe.scoped(subject)
      |> Safe.one()
    end
  end
end
