defmodule PortalAPI.GatewayController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Filters
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database
  alias Portal.Presence

  tags ["Gateways"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Gateways",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Gateways returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [in: :query, description: "Filter to the Gateway with this exact name", type: :string],
      ipv4: [in: :query, description: "Filter to the Gateway with this exact tunnel IPv4 address", type: :string],
      ipv6: [in: :query, description: "Filter to the Gateway with this exact tunnel IPv6 address", type: :string]
    ],
    responses:
      [ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    # Gateways are always nested under /sites/:site_id, so site_id is always present.
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts =
           list_opts
           |> Keyword.put(:preload, [:online?])
           |> Keyword.put(:filter, coerce_filters(params)),
         {:ok, gateways, metadata} <- Database.list_gateways(conn.assigns.subject, list_opts) do
      json(conn, JSON.encode(gateways, metadata, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params) do
    [site_id: params["site_id"]]
    |> Filters.maybe_append(:name, params["name"])
    |> Filters.maybe_append(:ipv4, params["ipv4"])
    |> Filters.maybe_append(:ipv6, params["ipv6"])
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :show,
    summary: "Show Gateway",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"site_id" => site_id, "id" => id}) do
    with {:ok, gateway} <- Database.fetch_gateway(site_id, id, conn.assigns.subject) do
      gateway = Presence.Devices.preload_presence([gateway]) |> List.first()
      json(conn, JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Provision a Gateway",
    description: """
    Creates a Gateway and mints its single-owner token in one call. The \
    token is returned once here - store it securely. If it's lost, rotate \
    it via `POST /sites/{site_id}/gateways/{gateway_id}/token/rotate` once \
    the Gateway has connected, or delete and re-provision it.

    `name` is optional; a random name is generated when omitted. `ipv4` \
    and `ipv6` are the Gateway's tunnel addresses, allocated from the \
    account's pool when the Gateway row is created - they are always \
    present in this response, before the Gateway has ever connected.
    """,
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Gateway attributes", "application/json", PortalAPI.Schemas.Gateway.CreateRequest,
       required: false},
    responses:
      [
        created:
          {"Provisioned Gateway Response", "application/json",
           PortalAPI.Schemas.Gateway.ProvisionResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"site_id" => site_id} = params) do
    subject = conn.assigns.subject
    name = get_in(params, ["gateway", "name"])

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {:ok, gateway, _token, encoded_token} <- Database.provision_gateway(site, name, subject) do
      gateway = Presence.Devices.preload_presence([gateway]) |> List.first()

      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/sites/#{site_id}/gateways/#{gateway}")
      |> json(JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema, token: encoded_token))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update,
    summary: "Update a Gateway (rename)",
    description: """
    Renames a Gateway. Gateways otherwise self-register their configuration \
    (name, IP addresses) on first connect and can only be renamed, not \
    fully edited, via this endpoint.
    """,
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Gateway attributes", "application/json", PortalAPI.Schemas.Gateway.UpdateRequest,
       required: true},
    responses:
      [ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"site_id" => site_id, "id" => id, "gateway" => %{"name" => name}}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Database.fetch_gateway(site_id, id, subject),
         {:ok, gateway} <- Database.rename_gateway(gateway, name, subject) do
      gateway = Presence.Devices.preload_presence([gateway]) |> List.first()
      json(conn, JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Delete a Gateway",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"site_id" => site_id, "id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Database.fetch_gateway(site_id, id, subject),
         {:ok, gateway} <- Database.delete_gateway(gateway, subject) do
      json(conn, JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Devices
    alias Portal.Safe
    alias Portal.Site
    alias Portal.Device
    alias Portal.Presence

    def fetch_site(id, subject) do
      result =
        from(s in Site, where: s.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        site -> {:ok, site}
      end
    end

    def provision_gateway(site, name, subject) do
      Devices.provision_gateway(site, name, subject)
    end

    def list_gateways(subject, opts \\ []) do
      from(d in Device, as: :gateways)
      |> where([gateways: d], d.type == :gateway)
      |> with_token_rotation()
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    # Surfaces the rotation state of the token the gateway last connected
    # with, so a caller can tell a pending rotation from a completed one.
    # Left join because gateway_token_id is null until the gateway's first
    # connect, and select_merge because rotated_at lives on the token
    # rather than the device.
    defp with_token_rotation(queryable) do
      queryable
      |> join(:left, [gateways: d], t in Portal.GatewayToken,
        on: t.id == d.gateway_token_id and t.account_id == d.account_id,
        as: :gateway_token
      )
      |> select_merge([gateway_token: t], %{gateway_token_rotated_at: t.rotated_at})
    end

    def cursor_fields do
      [
        {:gateways, :asc, :inserted_at},
        {:gateways, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Presence.Devices.preload_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :name,
          title: "Name",
          type: :string,
          fun: &filter_by_name/2
        },
        %Portal.Repo.Filter{
          name: :ipv4,
          title: "IPv4",
          type: {:string, :ip},
          fun: &filter_by_ipv4/2
        },
        %Portal.Repo.Filter{
          name: :ipv6,
          title: "IPv6",
          type: {:string, :ip},
          fun: &filter_by_ipv6/2
        }
      ]
    end

    defp filter_by_site_id(queryable, site_id) do
      dynamic = dynamic([gateways: d], d.site_id == ^site_id)
      {queryable, dynamic}
    end

    defp filter_by_name(queryable, name) do
      dynamic = dynamic([gateways: d], d.name == ^name)
      {queryable, dynamic}
    end

    defp filter_by_ipv4(queryable, ipv4) do
      dynamic = dynamic([gateways: d], d.ipv4 == ^ipv4)
      {queryable, dynamic}
    end

    defp filter_by_ipv6(queryable, ipv6) do
      dynamic = dynamic([gateways: d], d.ipv6 == ^ipv6)
      {queryable, dynamic}
    end

    def fetch_gateway(site_id, id, subject) do
      result =
        from(d in Device, as: :gateways)
        |> where([gateways: d], d.id == ^id and d.type == :gateway and d.site_id == ^site_id)
        |> with_token_rotation()
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        gateway -> {:ok, gateway}
      end
    end

    # Mirrors PortalWeb.Live.Sites.Database.rename_gateway/3. Safe.update/1
    # re-applies Device.changeset/1 centrally regardless of this bypass,
    # but that's fine - :firezone_id is only required for :client devices
    # (a gateway legitimately has none until first connect).
    @spec rename_gateway(Device.t(), String.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
    def rename_gateway(gateway, name, subject) do
      gateway
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Portal.Changeset.trim_change([:name])
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.validate_length(:name, min: 1, max: 255)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_gateway(gateway, subject) do
      case Safe.scoped(gateway, subject) |> Safe.delete() do
        {:ok, deleted_gateway} ->
          {:ok, Presence.Devices.preload_presence([deleted_gateway]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
