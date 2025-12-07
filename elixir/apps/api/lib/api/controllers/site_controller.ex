defmodule API.SiteController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.{Auth, Safe}
  alias __MODULE__.DB

  action_fallback API.FallbackController

  tags ["Sites"]

  operation :index,
    summary: "List Sites",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Sites returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Site Response", "application/json", API.Schemas.Site.ListResponse}
    ]

  # List Sites
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, sites, metadata} <- DB.list_sites(conn.assigns.subject, list_opts) do
      render(conn, :index, sites: sites, metadata: metadata)
    end
  end

  operation :show,
    summary: "Show Site",
    parameters: [
      id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Site Response", "application/json", API.Schemas.Site.Response}
    ]

  # Show a specific Site
  def show(conn, %{"id" => id}) do
    with {:ok, site} <- DB.fetch_site(id, conn.assigns.subject) do
      render(conn, :show, site: site)
    end
  end

  operation :create,
    summary: "Create Site",
    parameters: [],
    request_body:
      {"Site Attributes", "application/json", API.Schemas.Site.Request, required: true},
    responses: [
      ok: {"Site Response", "application/json", API.Schemas.Site.Response}
    ]

  # Create a new Site
  def create(conn, %{"site" => params}) do
    changeset = create_changeset(conn.assigns.subject.account, params, conn.assigns.subject)

    with {:ok, site} <- DB.create_site(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/sites/#{site}")
      |> render(:show, site: site)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  defp create_changeset(account, attrs, subject) do
    import Ecto.Changeset

    %Domain.Site{}
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> put_change(:account_id, account.id)
    |> put_change(:managed_by, :account)
    |> cast_assoc(:tokens,
      required: false,
      with: fn struct, attrs ->
        import Ecto.Changeset

        struct
        |> cast(attrs, [:name, :expires_at])
        |> put_change(:type, :site)
        |> put_change(:account_id, subject.account.id)
        |> Domain.Token.changeset()
      end
    )
  end

  operation :update,
    summary: "Update a Site",
    parameters: [
      id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Site Attributes", "application/json", API.Schemas.Site.Request, required: true},
    responses: [
      ok: {"Site Response", "application/json", API.Schemas.Site.Response}
    ]

  # Update a Site
  def update(conn, %{"id" => id, "site" => params}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(id, subject),
         {:ok, site} <- DB.update_site(site, params, subject) do
      render(conn, :show, site: site)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  operation :delete,
    summary: "Delete a Site",
    parameters: [
      id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Site Response", "application/json", API.Schemas.Site.Response}
    ]

  # Delete a Site
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(id, subject),
         {:ok, site} <- DB.delete_site(site, subject) do
      render(conn, :show, site: site)
    end
  end

  operation :create_token,
    summary: "Create a Token",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"New Token Response", "application/json", API.Schemas.SiteToken.NewToken}
    ]

  # Create a Site Token (used for deploying a gateway)
  def create_token(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(site_id, subject),
         {:ok, token, encoded_token} <-
           DB.create_token(site, %{}, subject) do
      conn
      |> put_status(:created)
      |> render(:token, token: token, encoded_token: encoded_token)
    end
  end

  operation :delete_token,
    summary: "Delete a Token",
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
      ok: {"Deleted Token Response", "application/json", API.Schemas.SiteToken.DeletedToken}
    ]

  # Delete/Revoke a Site Token
  def delete_token(conn, %{"site_id" => _site_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- DB.fetch_token(token_id, subject),
         {:ok, deleted_token} <- DB.delete_token(token, subject) do
      render(conn, :deleted_token, token: deleted_token)
    end
  end

  operation :delete_all_tokens,
    summary: "Delete all Tokens for a given Site",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Deleted Tokens Response", "application/json", API.Schemas.SiteToken.DeletedTokens}
    ]

  def delete_all_tokens(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(site_id, subject),
         {deleted_count, _} <- DB.delete_all_site_tokens(site, subject) do
      render(conn, :deleted_tokens, %{count: deleted_count})
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Billing, Token}
    alias Domain.Site

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

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

    def create_site(changeset, subject) do
      with true <- Billing.can_create_sites?(subject.account) do
        Safe.scoped(changeset, subject)
        |> Safe.insert()
      else
        false -> {:error, :sites_limit_reached}
      end
    end

    def update_site(site, attrs, subject) do
      site
      |> Safe.preload(:account)
      |> changeset(attrs, subject)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_site(site, subject) do
      site
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def create_token(site, attrs, subject) do
      attrs =
        Map.merge(attrs, %{
          "type" => :site,
          "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
          "account_id" => site.account_id,
          "site_id" => site.id
        })

      with {:ok, token} <- Auth.create_token(attrs, subject) do
        {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Auth.encode_fragment!(token)}
      end
    end

    def fetch_token(id, subject) do
      result =
        from(t in Token,
          where: t.id == ^id,
          where: t.expires_at > ^DateTime.utc_now() or is_nil(t.expires_at)
        )
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

    def delete_all_site_tokens(site, subject) do
      import Ecto.Query
      query = from(t in Token, where: t.site_id == ^site.id)
      Safe.scoped(query, subject) |> Safe.delete_all()
    end

    defp changeset(site, attrs, _subject) do
      import Ecto.Changeset

      site
      |> cast(attrs, [:name])
      |> validate_required([:name])
    end

    def cursor_fields do
      [
        {:sites, :asc, :inserted_at},
        {:sites, :asc, :id}
      ]
    end
  end
end
