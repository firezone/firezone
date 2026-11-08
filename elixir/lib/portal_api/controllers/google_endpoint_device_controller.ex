defmodule PortalAPI.GoogleEndpointDeviceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias PortalAPI.JSON
  alias __MODULE__.Database

  tags ["Google Endpoint Devices"]

  plug :require_device_posture

  defp require_device_posture(conn, _opts) do
    if Portal.Account.device_posture_enabled?(conn.assigns.subject.account) do
      conn
    else
      conn
      |> Error.handle({:error, :forbidden, reason: "This feature is not enabled for your account."})
      |> Plug.Conn.halt()
    end
  end

  # coveralls-ignore-start
  operation :index,
    summary: "List synced Google Endpoint devices",
    parameters: [
      limit: [in: :query, description: "Limit devices returned", schema: PortalAPI.Pagination.limit_schema()],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Google Endpoint device response", "application/json",
           PortalAPI.Schemas.GoogleEndpointDevice.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a synced Google Endpoint device",
    parameters: [
      google_endpoint_device: [
        in: :path,
        description: "Synced Google Endpoint device ID, the part of its resource name after `devices/`",
        type: :string
      ]
    ],
    responses:
      [
        ok:
          {"Google Endpoint device response", "application/json",
           PortalAPI.Schemas.GoogleEndpointDevice.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  def index(conn, params) do
    with {:ok, opts} <- Pagination.params_to_list_opts(params),
         {:ok, devices, metadata} <- Database.list_devices(conn.assigns.subject, opts) do
      json(conn, JSON.encode(devices, metadata))
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"google_endpoint_device" => id}) do
    with {:ok, device} <- Database.fetch_device(id, conn.assigns.subject) do
      json(conn, JSON.encode(device))
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{GoogleEndpoint, Safe}

    def list_devices(subject, opts) do
      from(d in GoogleEndpoint.Device, as: :google_endpoint_devices)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_device(id, subject) do
      case from(d in GoogleEndpoint.Device, where: d.google_id == ^id)
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        device -> {:ok, device}
      end
    end

    def cursor_fields do
      [
        {:google_endpoint_devices, :asc, :inserted_at},
        {:google_endpoint_devices, :asc, :google_id}
      ]
    end

    def preloads, do: []
  end
end
