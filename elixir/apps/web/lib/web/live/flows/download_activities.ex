defmodule Web.Flows.DownloadActivities do
  use Web, :controller
  alias Domain.Flows

  def download(conn, %{"id" => id}) do
    with {:ok, flow} <- Flows.fetch_flow_by_id(id, conn.assigns.subject) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"flow-activities-#{flow.id}.csv\""
      )
      |> put_root_layout(false)
      |> send_chunked(200)
      |> send_csv_header()
      |> stream_csv_body(flow)
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp send_csv_header(conn) do
    iodata =
      Web.CSV.dump_to_iodata([~w[
        window_started_at window_ended_at
        destination
        connectivity_type
        rx_bytes tx_bytes
      ]])

    {:ok, conn} = chunk(conn, iodata)
    conn
  end

  defp stream_csv_body(conn, flow, cursor \\ nil) do
    with {:ok, activities, activities_metadata} <-
           Flows.list_flow_activities_for(
             flow,
             flow.inserted_at,
             flow.expires_at,
             conn.assigns.subject,
             page: [cursor: cursor, limit: 100]
           ),
         {:ok, conn} <- stream_csv_rows(conn, activities) do
      if activities_metadata.next_page_cursor do
        stream_csv_body(conn, flow, activities_metadata.next_page_cursor)
      else
        conn
      end
    else
      {:error, _reason} ->
        conn
    end
  end

  defp stream_csv_rows(conn, activities) do
    iodata =
      activities
      |> Enum.map(fn activity ->
        [
          to_string(activity.window_started_at),
          to_string(activity.window_ended_at),
          to_string(activity.destination),
          to_string(activity.connectivity_type),
          activity.rx_bytes,
          activity.tx_bytes
        ]
      end)
      |> Web.CSV.dump_to_iodata()

    case chunk(conn, iodata) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end
end
