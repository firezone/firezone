defmodule PortalAPI.GatewayTokenController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.{Auth, Safe}
  alias __MODULE__.DB

  action_fallback PortalAPI.FallbackController

  tags ["Gateway Tokens"]

  operation :create,
    summary: "Create a Gateway Token",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"New Token Response", "application/json", PortalAPI.Schemas.GatewayToken.Response}
    ]

  def create(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(site_id, subject),
         {:ok, token} <- Auth.create_gateway_token(site, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Auth.encode_fragment!(token))
    end
  end

  operation :delete,
    summary: "Delete a Gateway Token",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Token ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Deleted Token Response", "application/json",
         PortalAPI.Schemas.GatewayToken.DeletedResponse}
    ]

  def delete(conn, %{"site_id" => _site_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- DB.fetch_token(token_id, subject),
         {:ok, deleted_token} <- DB.delete_token(token, subject) do
      render(conn, :deleted, token: deleted_token)
    end
  end

  operation :delete_all,
    summary: "Delete all Gateway Tokens for a Site",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Deleted Tokens Response", "application/json",
         PortalAPI.Schemas.GatewayToken.DeletedAllResponse}
    ]

  def delete_all(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(site_id, subject),
         {deleted_count, _} <- DB.delete_all_tokens(site, subject) do
      render(conn, :deleted_all, count: deleted_count)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{Site, GatewayToken}

    def fetch_site(id, subject) do
      result =
        from(s in Site, as: :sites)
        |> where([sites: s], s.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        site -> {:ok, site}
      end
    end

    def fetch_token(id, subject) do
      result =
        from(t in GatewayToken, where: t.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        token -> {:ok, token}
      end
    end

    def delete_token(token, subject) do
      token
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def delete_all_tokens(site, subject) do
      from(t in GatewayToken, where: t.site_id == ^site.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end
end
