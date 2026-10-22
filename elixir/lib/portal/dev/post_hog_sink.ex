defmodule Portal.Dev.PostHogSink do
  @moduledoc """
  Stands in for PostHog in development: logs every request body instead of sending it.

  Enable with `POSTHOG_DEV_SINK=true`, see `config/dev.exs`.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    Logger.info(
      "PostHog #{conn.method} #{conn.request_path}\n" <>
        inspect(JSON.decode!(body), pretty: true, limit: :infinity)
    )

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, ~s({"status":"Ok"}))
  end
end
