defmodule PortalAPI.ResourceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias PortalAPI.Filters
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Resources"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Resources",
    parameters: [
      limit: [in: :query, description: "Limit Resources returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [
        in: :query,
        description: "Filter to Resources with this exact name",
        type: :string
      ],
      type: [
        in: :query,
        description: "Filter to Resources of this type: cidr, ip, dns, or static_device_pool.",
        type: :string,
        example: "dns"
      ],
      site_id: [
        in: :query,
        description: "Filter to Resources connected to this Site",
        type: :string
      ],
      address: [
        in: :query,
        description: "Filter to Resources with this exact address",
        type: :string
      ],
      ip_stack: [
        in: :query,
        description: "Filter to Resources with this exact ip_stack",
        type: :string,
        example: "dual"
      ]
    ],
    responses:
      [ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, coerce_filters(params)),
         {:ok, resources, metadata} <-
           Database.list_resources(conn.assigns.subject, list_opts) do
      render(conn, :index, resources: resources, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params) do
    []
    |> Filters.maybe_append(:name, params["name"])
    |> Filters.maybe_append(:type, params["type"])
    |> Filters.maybe_append(:site_id, params["site_id"])
    |> Filters.maybe_append(:address, params["address"])
    |> Filters.maybe_append(:ip_stack, params["ip_stack"])
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :show,
    summary: "Show Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- Database.fetch_resource(id, conn.assigns.subject) do
      render(conn, :show, resource: resource)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Create Resource",
    parameters: [],
    request_body:
      {"Resource Attributes", "application/json", PortalAPI.Schemas.Resource.CreateRequest,
       required: true},
    responses:
      [created: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"resource" => params}) do
    attrs = set_param_defaults(params)
    changeset = create_changeset(attrs, conn.assigns.subject)

    with {:ok, resource} <- Database.insert_resource(changeset, conn.assigns.subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/resources/#{resource}")
      |> render(:show, resource: resource)
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update,
    summary: "Update Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Resource Attributes", "application/json", PortalAPI.Schemas.Resource.UpdateRequest,
       required: true},
    responses:
      [ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "resource" => params}) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Database.fetch_resource(id, subject),
         :ok <- validate_not_internet_resource(resource),
         {:ok, resource} <- Database.update_resource(resource, params, subject) do
      render(conn, :show, resource: resource)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Delete Resource",
    parameters: [
      id: [
        in: :path,
        description: "Resource ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Database.fetch_resource(id, subject),
         :ok <- validate_not_internet_resource(resource),
         {:ok, resource} <- Database.delete_resource(resource, subject) do
      render(conn, :show, resource: resource)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp validate_not_internet_resource(%{type: :internet}),
    do: {:error, :forbidden, reason: "Internet Resource cannot be modified"}

  defp validate_not_internet_resource(_resource), do: :ok

  defp set_param_defaults(params) do
    Map.put_new(params, "filters", %{})
  end

  defp create_changeset(attrs, subject) do
    changeset =
      %Portal.Resource{account_id: subject.account.id}
      |> Ecto.Changeset.cast(attrs, ~w[address address_description name type ip_stack site_id]a)
      |> Portal.Resource.changeset()

    required =
      case Ecto.Changeset.get_field(changeset, :type) do
        :static_device_pool -> ~w[name type]a
        :internet -> ~w[name type site_id]a
        _ -> ~w[name type site_id address]a
      end

    changeset
    |> Ecto.Changeset.validate_required(required)
    |> Database.reject_device_pool_type()
    |> Portal.Resource.validate_site_matches_type(subject)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def list_resources(subject, opts \\ []) do
      from(r in Portal.Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Name",
          type: :string,
          fun: &filter_by_name/2
        },
        %Portal.Repo.Filter{
          name: :type,
          title: "Type",
          type: {:string, :select},
          values: [
            {"CIDR", "cidr"},
            {"IP", "ip"},
            {"DNS", "dns"},
            {"Static Device Pool", "static_device_pool"}
          ],
          fun: &filter_by_type/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :address,
          title: "Address",
          type: :string,
          fun: &filter_by_address/2
        },
        %Portal.Repo.Filter{
          name: :ip_stack,
          title: "IP Stack",
          type: {:string, :select},
          values: [
            {"IPv4 Only", "ipv4_only"},
            {"IPv6 Only", "ipv6_only"},
            {"Dual", "dual"}
          ],
          fun: &filter_by_ip_stack/2
        }
      ]
    end

    defp filter_by_name(queryable, name) do
      dynamic = dynamic([resources: r], r.name == ^name)
      {queryable, dynamic}
    end

    defp filter_by_type(queryable, "cidr") do
      dynamic = dynamic([resources: r], r.type == :cidr)
      {queryable, dynamic}
    end

    defp filter_by_type(queryable, "ip") do
      dynamic = dynamic([resources: r], r.type == :ip)
      {queryable, dynamic}
    end

    defp filter_by_type(queryable, "dns") do
      dynamic = dynamic([resources: r], r.type == :dns)
      {queryable, dynamic}
    end

    defp filter_by_type(queryable, "static_device_pool") do
      dynamic = dynamic([resources: r], r.type == :static_device_pool)
      {queryable, dynamic}
    end

    defp filter_by_site_id(queryable, site_id) do
      dynamic = dynamic([resources: r], r.site_id == ^site_id)
      {queryable, dynamic}
    end

    defp filter_by_address(queryable, address) do
      dynamic = dynamic([resources: r], r.address == ^address)
      {queryable, dynamic}
    end

    defp filter_by_ip_stack(queryable, "ipv4_only") do
      dynamic = dynamic([resources: r], r.ip_stack == :ipv4_only)
      {queryable, dynamic}
    end

    defp filter_by_ip_stack(queryable, "ipv6_only") do
      dynamic = dynamic([resources: r], r.ip_stack == :ipv6_only)
      {queryable, dynamic}
    end

    defp filter_by_ip_stack(queryable, "dual") do
      dynamic = dynamic([resources: r], r.ip_stack == :dual)
      {queryable, dynamic}
    end

    def fetch_resource(id, subject) do
      result =
        from(r in Portal.Resource, where: r.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        resource -> {:ok, resource}
      end
    end

    def update_resource(resource, attrs, subject) do
      resource
      |> changeset(attrs, subject)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_resource(resource, subject) do
      resource
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def insert_resource(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    # Device pools are not creatable through the REST API for now. They can
    # still be created in the admin portal, and every other operation here -
    # read, update, delete, and the /resources/:id/pool_members endpoints -
    # works normally against a pool that already exists.
    #
    # What this rejects is any request that *changes* a Resource's type to
    # static_device_pool, which is why it runs on the update path too: doing
    # it there would be creating a pool by another name. It is not a block on
    # updating pools.
    #
    # The distinction falls out of validate_exclusion/4 running through
    # validate_change/3, which only fires when the field is actually changed,
    # and cast/3 only recording a change when the value differs from the
    # stored one. So renaming an existing pool passes, and so does a PUT that
    # restates the pool's own type - only a genuine transition into
    # static_device_pool is refused.
    #
    # To re-enable, in this file:
    #
    #   1. Delete this function and both of its call sites (create_changeset/2
    #      and Database.changeset/3).
    #   2. Add "static_device_pool" back to the `type` enum in
    #      PortalAPI.Schemas.Resource's CreateParams and UpdateParams, and
    #      restore the "site_id is required unless type is static_device_pool"
    #      note in the CreateRequest description.
    #
    # Everything else already supports pools and needs no change: the
    # required-fields branches above and in Database.changeset/3 already
    # special-case them, Portal.Resource nulls site_id for pool types, and
    # PortalAPI.PoolMemberController manages membership. Outside this repo,
    # the Terraform provider's firezone_resource still advertises
    # static_device_pool in its type validator - it will start getting 422s
    # until it is updated to match.
    def reject_device_pool_type(changeset) do
      Ecto.Changeset.validate_exclusion(changeset, :type, [:static_device_pool],
        message: "device pools cannot be created via the API"
      )
    end

    defp changeset(resource, attrs, subject) do
      update_fields = ~w[address address_description name type ip_stack site_id]a

      changeset =
        resource
        |> Ecto.Changeset.cast(attrs, update_fields)
        |> Portal.Resource.changeset()

      required_fields =
        case Ecto.Changeset.get_field(changeset, :type) do
          :static_device_pool -> ~w[name type]a
          :internet -> ~w[name type site_id]a
          _ -> ~w[name type site_id address]a
        end

      changeset
      |> Ecto.Changeset.validate_required(required_fields)
      |> reject_device_pool_type()
      |> Portal.Resource.validate_site_matches_type(subject)
    end

    def cursor_fields do
      [
        {:resources, :asc, :inserted_at},
        {:resources, :asc, :id}
      ]
    end
  end
end
