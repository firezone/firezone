defmodule Web.Flows.DownloadActivities do
  use Web, :controller
  alias Domain.Flows

  def download(conn, %{"id" => id}) do
    with {:ok, flow} <- Flows.fetch_flow_by_id(id, conn.assigns.subject),
         {:ok, activities} <-
           Flows.list_flow_activities_for(
             flow,
             flow.inserted_at,
             flow.expires_at,
             conn.assigns.subject
           ) do
      fields = ~w[window_started_at window_ended_at destination rx_bytes tx_bytes]

      rows =
        Enum.map(activities, fn activity ->
          [
            to_string(activity.window_started_at),
            to_string(activity.window_ended_at),
            to_string(activity.destination),
            activity.rx_bytes,
            activity.tx_bytes
          ]
        end)

      iodata = Web.CSV.dump_to_iodata([fields] ++ rows)

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"export.csv\"")
      |> put_root_layout(false)
      |> send_resp(200, iodata)
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end
end
