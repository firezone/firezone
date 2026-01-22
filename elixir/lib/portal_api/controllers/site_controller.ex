defmodule PortalAPI.SiteController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.DB

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
      ok: {"Site Response", "application/json", PortalAPI.Schemas.Site.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, sites, metadata} <- DB.list_sites(conn.assigns.subject, list_opts) do
      render(conn, :index, sites: sites, metadata: metadata)
    else
      error -> Error.handle(conn, error)
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
      ok: {"Site Response", "application/json", PortalAPI.Schemas.Site.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, site} <- DB.fetch_site(id, conn.assigns.subject) do
      render(conn, :show, site: site)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :create,
    summary: "Create Site",
    parameters: [],
    request_body:
      {"Site Attributes", "application/json", PortalAPI.Schemas.Site.Request, required: true},
    responses: [
      ok: {"Site Response", "application/json", PortalAPI.Schemas.Site.Response}
    ]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"site" => params}) do
    changeset = create_changeset(conn.assigns.subject.account, params)

    with {:ok, site} <- DB.create_site(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/sites/#{site}")
      |> render(:show, site: site)
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp create_changeset(account, attrs) do
    import Ecto.Changeset

    %Portal.Site{}
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> put_change(:account_id, account.id)
    |> put_change(:managed_by, :account)
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
      {"Site Attributes", "application/json", PortalAPI.Schemas.Site.Request, required: true},
    responses: [
      ok: {"Site Response", "application/json", PortalAPI.Schemas.Site.Response}
    ]

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "site" => params}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(id, subject),
         :ok <- validate_not_system_managed(site),
         {:ok, site} <- DB.update_site(site, params, subject) do
      render(conn, :show, site: site)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
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
      ok: {"Site Response", "application/json", PortalAPI.Schemas.Site.Response}
    ]

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- DB.fetch_site(id, subject),
         :ok <- validate_not_system_managed(site),
         {:ok, site} <- DB.delete_site(site, subject) do
      render(conn, :show, site: site)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp validate_not_system_managed(%{managed_by: :system}),
    do: {:error, :forbidden, reason: "System managed Site cannot be modified"}

  defp validate_not_system_managed(_site), do: :ok

  defmodule DB do
    import Ecto.Query
    alias Portal.{Safe, Billing}
    alias Portal.Site

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
