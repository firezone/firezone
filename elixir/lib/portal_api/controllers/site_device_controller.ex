defmodule PortalAPI.SiteDeviceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.JSON
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Presence
  alias __MODULE__.Database

  tags ["Sites"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Assign a Device to a Site",
    description: """
    Assigns an existing Gateway to the Site so it serves the Site's \
    Resources alongside any other Site it is assigned to. Only Gateways can \
    serve Resources for now; assigning any other Device returns 422.

    Assigning a Gateway to the Internet Site while it serves another Site, \
    or the other way round, has it serve the Internet Resource next to \
    other Resources: users with access to the Internet Resource can reach \
    any non-private address the Gateway can reach, and Gateways below 1.6.5 \
    do not route a Site's other Resources while serving the Internet \
    Resource.
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
      {"Device to assign", "application/json", PortalAPI.Schemas.SiteDevice.CreateRequest,
       required: true},
    responses:
      [
        created: {"Assigned Gateway", "application/json", PortalAPI.Schemas.Gateway.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"site_id" => site_id, "device" => %{"id" => device_id}}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {:ok, device_id} <- cast_id(device_id),
         {:ok, _site_device} <- Portal.Devices.assign_to_site(site, device_id, subject),
         {:ok, gateway} <- Database.fetch_gateway(site_id, device_id, subject) do
      gateway = Presence.Devices.preload_presence([gateway]) |> List.first()

      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/sites/#{site_id}/gateways/#{gateway}")
      |> json(JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      {:error, :not_a_gateway} ->
        Error.handle(
          conn,
          {:error, :unprocessable_entity,
           validation_errors: %{device_id: ["only gateways can serve a site's resources for now"]}}
        )

      {:error, :already_assigned} ->
        Error.handle(conn, {:error, :conflict, reason: "Device is already assigned to this Site"})

      error ->
        Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Remove a Device from a Site",
    description: """
    Takes the Gateway off the Site; it keeps serving any other Site it is \
    assigned to and is not deleted. A Gateway cannot be removed from the \
    only Site it serves: assign it to another Site first, or delete the \
    Gateway, which returns 409 otherwise.
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
        description: "Device ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"Removed Gateway", "application/json", PortalAPI.Schemas.Gateway.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :conflict,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"site_id" => site_id, "id" => device_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {:ok, gateway} <- Database.fetch_gateway(site_id, device_id, subject),
         {:ok, _device} <- Portal.Devices.unassign_from_site(site, gateway.id, subject) do
      gateway = Presence.Devices.preload_presence([gateway]) |> List.first()
      json(conn, JSON.encode(gateway, schema: PortalAPI.Schemas.Gateway.Schema))
    else
      {:error, :last_site} ->
        Error.handle(
          conn,
          {:error, :conflict,
           reason:
             "This is the only Site the Gateway serves; assign it to another Site first " <>
               "or delete the Gateway"}
        )

      error ->
        Error.handle(conn, error)
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Safe, Site}

    def fetch_site(id, subject) do
      from(s in Site, where: s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        site -> {:ok, site}
      end
    end

    # The gateway as the gateway routes render it, with the rotation state
    # of the token it last connected with, limited to the site's gateways.
    def fetch_gateway(site_id, id, subject) do
      from(d in Device, as: :gateways)
      |> where([gateways: d], d.id == ^id and d.type == :gateway)
      |> where(
        [gateways: d],
        exists(
          from(sd in Portal.SiteDevice,
            where:
              sd.account_id == parent_as(:gateways).account_id and
                sd.device_id == parent_as(:gateways).id and sd.site_id == ^site_id
          )
        )
      )
      |> join(:left, [gateways: d], t in Portal.ClientToken,
        on: t.id == d.token_id and t.account_id == d.account_id,
        as: :gateway_token
      )
      |> select_merge([gateway_token: t], %{gateway_token_rotated_at: t.rotated_at})
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end
  end
end
