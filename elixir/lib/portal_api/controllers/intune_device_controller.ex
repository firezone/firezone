defmodule PortalAPI.IntuneDeviceController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias PortalAPI.JSON
  alias __MODULE__.Database

  tags ["Intune Devices"]

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
    summary: "List synced Intune devices",
    parameters: [
      limit: [in: :query, description: "Limit devices returned", type: :integer],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [ok: {"Intune device response", "application/json", PortalAPI.Schemas.IntuneDevice.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a synced Intune device",
    parameters: [
      id: [in: :path, description: "Synced Intune device ID", type: :string]
    ],
    responses:
      [ok: {"Intune device response", "application/json", PortalAPI.Schemas.IntuneDevice.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  def index(conn, params) do
    with {:ok, opts} <- Pagination.params_to_list_opts(params),
         {:ok, devices, metadata} <- Database.list_devices(conn.assigns.subject, opts) do
      json(conn, %{data: JSON.encode(devices), metadata: Pagination.metadata(metadata)})
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, device} <- Database.fetch_device(id, conn.assigns.subject) do
      json(conn, %{data: JSON.encode(device)})
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Intune, Safe}

    def list_devices(subject, opts) do
      from(d in Intune.Device, as: :intune_devices)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_device(id, subject) do
      case from(d in Intune.Device, where: d.intune_id == ^id)
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        device -> {:ok, device}
      end
    end

    def cursor_fields do
      [{:intune_devices, :asc, :inserted_at}, {:intune_devices, :asc, :intune_id}]
    end

    def preloads, do: []
  end
end
