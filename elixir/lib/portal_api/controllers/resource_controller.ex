defmodule PortalAPI.ResourceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Filters
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Resources"]

  @site_id "0642e09d-b3a2-47e4-9cd1-c2195faeeb67"
  @group_id "b3a1c6e2-5f4d-4e7a-9c8b-1d2e3f4a5b6c"
  @client_ids ["7cb89288-1fb3-433e-a522-2d087e45988d", "cc9f561a-444d-4083-ab38-0abc6cf2314c"]

  @listed_devices %{"device" => %{"field" => "id", "op" => "in", "value" => @client_ids}}
  @own_devices %{"device" => %{"field" => "actor_id", "op" => "eq", "value" => %{"subject" => "actor_id"}}}
  @all_devices %{
    "device" => %{"field" => "account_id", "op" => "eq", "value" => %{"subject" => "account_id"}}
  }
  @actor_group %{"actor_group" => %{"field" => "id", "op" => "eq", "value" => @group_id}}

  @ip_resource %{
    "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
    "name" => "Prod DB",
    "type" => "ip",
    "address" => "10.0.0.10",
    "address_description" => "Production Database",
    "site_id" => @site_id,
    "filters" => [%{"protocol" => "tcp", "ports" => ["5432"]}]
  }

  @device_pool %{
    "id" => "5f0d3c1a-8e2b-4b7d-9a6c-3e4f5a6b7c8d",
    "name" => "My Devices",
    "type" => "device_pool",
    "address" => nil,
    "address_description" => nil,
    "filters" => [],
    "device_membership_criteria" => @own_devices
  }

  @create_examples %{
    "ip" => %OpenApiSpex.Example{
      summary: "IP Resource",
      value: %{"resource" => Map.drop(@ip_resource, ["id"])}
    },
    "listed_devices" => %OpenApiSpex.Example{
      summary: "Device pool of the Clients named",
      value: %{
        "resource" => %{
          "name" => "Build Machines",
          "type" => "device_pool",
          "device_membership_criteria" => @listed_devices
        }
      }
    },
    "own_devices" => %OpenApiSpex.Example{
      summary: "Device pool of the asking Actor's own Clients",
      value: %{
        "resource" => %{
          "name" => "My Devices",
          "type" => "device_pool",
          "device_membership_criteria" => @own_devices
        }
      }
    },
    "all_devices" => %OpenApiSpex.Example{
      summary: "Device pool of every Client in the Account",
      value: %{
        "resource" => %{
          "name" => "All Devices",
          "type" => "device_pool",
          "device_membership_criteria" => @all_devices
        }
      }
    },
    "actor_group" => %OpenApiSpex.Example{
      summary: "Device pool of the Clients of every Actor in one Group",
      value: %{
        "resource" => %{
          "name" => "Engineering Devices",
          "type" => "device_pool",
          "device_membership_criteria" => @actor_group
        }
      }
    }
  }

  @update_examples %{
    "rename" => %OpenApiSpex.Example{
      summary: "Rename a Resource",
      value: %{"resource" => %{"name" => "Prod DB (primary)"}}
    },
    "set_pool_members" => %OpenApiSpex.Example{
      summary: "Replace the Clients a device pool names",
      value: %{"resource" => %{"device_membership_criteria" => @listed_devices}}
    },
    "convert_to_device_pool" => %OpenApiSpex.Example{
      summary: "Convert a Resource to a device pool",
      value: %{"resource" => %{"type" => "device_pool", "device_membership_criteria" => @actor_group}}
    }
  }

  @resource_examples %{
    "ip" => %OpenApiSpex.Example{summary: "IP Resource", value: %{"data" => @ip_resource}},
    "device_pool" => %OpenApiSpex.Example{summary: "Device pool", value: %{"data" => @device_pool}}
  }

  @list_examples %{
    "resources" => %OpenApiSpex.Example{
      summary: "An IP Resource and a device pool",
      value: %{
        "data" => [@ip_resource, @device_pool],
        "metadata" => %{"limit" => 10, "count" => 2, "next_page" => nil, "prev_page" => nil}
      }
    }
  }

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Resources",
    parameters: [
      limit: [in: :query, description: "Limit Resources returned", schema: PortalAPI.Pagination.limit_schema(), example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [
        in: :query,
        description: "Filter to Resources with this exact name",
        type: :string
      ],
      type: [
        in: :query,
        description: "Filter to Resources of this type: cidr, ip, dns, or device_pool.",
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
      [
        ok:
          {"Resource Response", "application/json", PortalAPI.Schemas.Resource.ListResponse,
           examples: @list_examples}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, coerce_filters(params)),
         {:ok, resources, metadata} <-
           Database.list_resources(conn.assigns.subject, list_opts) do
      json(conn, JSON.encode(resources, metadata))
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
      [
        ok:
          {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response,
           examples: @resource_examples}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- Database.fetch_resource(id, conn.assigns.subject) do
      json(conn, JSON.encode(resource))
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
       required: true, examples: @create_examples},
    responses:
      [
        created:
          {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response,
           examples: @resource_examples}
      ] ++
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
      |> json(JSON.encode(resource))
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
       required: true, examples: @update_examples},
    responses:
      [
        ok:
          {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response,
           examples: @resource_examples}
      ] ++
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
      json(conn, JSON.encode(resource))
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
      [
        ok:
          {"Resource Response", "application/json", PortalAPI.Schemas.Resource.Response,
           examples: @resource_examples}
      ] ++
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
      json(conn, JSON.encode(resource))
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
      |> Ecto.Changeset.cast(attrs, Database.writable_fields())
      |> Portal.Resource.changeset()

    required =
      case Ecto.Changeset.get_field(changeset, :type) do
        :device_pool -> ~w[name type]a
        :internet -> ~w[name type site_id]a
        _ -> ~w[name type site_id address]a
      end

    changeset
    |> Ecto.Changeset.validate_required(required)
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
            {"Device Pool", "device_pool"}
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

    defp filter_by_type(queryable, "device_pool") do
      dynamic = dynamic([resources: r], r.type == :device_pool)
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

    def writable_fields do
      ~w[address address_description name type ip_stack site_id device_membership_criteria]a
    end

    defp changeset(resource, attrs, subject) do
      changeset =
        resource
        |> Ecto.Changeset.cast(attrs, writable_fields())
        |> Portal.Resource.changeset()

      required_fields =
        case Ecto.Changeset.get_field(changeset, :type) do
          :device_pool -> ~w[name type]a
          :internet -> ~w[name type site_id]a
          _ -> ~w[name type site_id address]a
        end

      changeset
      |> Ecto.Changeset.validate_required(required_fields)
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
