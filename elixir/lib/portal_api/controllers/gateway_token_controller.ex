defmodule PortalAPI.GatewayTokenController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.Auth
  alias PortalAPI.Error
  alias __MODULE__.Database

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

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {:ok, token} <- Auth.create_gateway_token(site, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Auth.encode_fragment!(token))
    else
      error -> Error.handle(conn, error)
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

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"site_id" => _site_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- Database.fetch_token(token_id, subject),
         {:ok, deleted_token} <- Database.delete_token(token, subject) do
      render(conn, :deleted, token: deleted_token)
    else
      error -> Error.handle(conn, error)
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

  @spec delete_all(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_all(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {deleted_count, _} <- Database.delete_all_tokens(site, subject) do
      render(conn, :deleted_all, count: deleted_count)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Site
    alias Portal.GatewayToken

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
