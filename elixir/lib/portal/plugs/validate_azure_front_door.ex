defmodule Portal.Plugs.ValidateAzureFrontDoor do
  @moduledoc """
  Validates the X-Azure-FDID header matches the configured Azure Front Door ID.

  This plug provides defense-in-depth security for Azure deployments. The NSG allows
  traffic from all Azure Front Door instances globally (via AzureFrontDoor.Backend
  service tag), so this header validation ensures only our specific Front Door
  instance can send traffic to the application.

  When `azure_front_door_id` is not configured, this plug is a no-op.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    case Portal.Config.fetch_env!(:portal, :azure_front_door_id) do
      nil ->
        # Not configured, skip validation
        conn

      expected_id ->
        validate_front_door_id(conn, expected_id)
    end
  end

  defp validate_front_door_id(conn, expected_id) do
    expected_id_lower = String.downcase(expected_id)

    case get_req_header(conn, "x-azure-fdid") do
      [received_id] ->
        if String.downcase(received_id) == expected_id_lower do
          conn
        else
          Logger.warning("Rejected request with invalid X-Azure-FDID header",
            expected: expected_id,
            received: received_id,
            remote_ip: conn.remote_ip
          )

          reject(conn)
        end

      [] ->
        Logger.warning("Rejected request missing X-Azure-FDID header",
          expected: expected_id,
          remote_ip: conn.remote_ip
        )

        reject(conn)

      _multiple ->
        Logger.warning("Rejected request with multiple X-Azure-FDID headers",
          expected: expected_id,
          remote_ip: conn.remote_ip
        )

        reject(conn)
    end
  end

  # TODO: Change to 403 Forbidden once the majority of clients no longer
  # disconnect immediately on 4xx errors.
  defp reject(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "Bad Gateway")
    |> halt()
  end
end
