defmodule Portal.ConnectionWarmer do
  @moduledoc """
  Pre-creates Finch connection pools for known production hosts at startup.

  Finch creates a pool per host lazily, on the first request to that host. When
  several requests to a cold host arrive concurrently (for example parallel
  directory sync jobs right after a deploy), the requests that lose the
  pool-construction race fail with `%Finch.Error{reason: :pool_not_available}`.

  Issuing one request per host at boot creates and registers each pool up front,
  so later requests never race construction. The pool is created during request
  setup, before the connection is established, so it is warmed even when the
  warmup request itself fails. Pools persist for the lifetime of the node
  (`pool_max_idle_time` defaults to `:infinity`), so a single pass is enough.
  """

  require Logger

  @hosts [
    "https://graph.microsoft.com",
    "https://login.microsoftonline.com",
    "https://admin.googleapis.com",
    "https://www.googleapis.com",
    "https://oauth2.googleapis.com",
    "https://accounts.google.com",
    "https://api.stripe.com"
  ]

  @request_timeout :timer.seconds(5)

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&run/0]},
      restart: :temporary
    }
  end

  def run do
    @hosts
    |> Task.async_stream(&warm/1,
      max_concurrency: length(@hosts),
      timeout: @request_timeout + :timer.seconds(2),
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp warm(url) do
    case Req.head(url, retry: false, receive_timeout: @request_timeout) do
      {:ok, response} ->
        Logger.debug("Warmed connection pool", url: url, status: response.status)

      {:error, reason} ->
        Logger.debug("Connection pool warmup failed", url: url, reason: inspect(reason))
    end
  rescue
    error ->
      Logger.debug("Connection pool warmup raised", url: url, error: inspect(error))
  end
end
