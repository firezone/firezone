defmodule Portal.Datadog.APIClient do
  @moduledoc """
  Datadog Logs intake adapter for log sink delivery.

  Batches are posted to `https://http-intake.logs.<site>/api/v2/logs` as a
  JSON array, authenticated with the sink's API key. Datadog acknowledges
  accepted payloads with a 202.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.Datadog

  @impl true
  def encode_event(_sink, stream, {time, event}) do
    JSON.encode!(%{
      "ddsource" => "firezone",
      "ddtags" => "stream:#{stream}",
      "service" => "firezone",
      "timestamp" => round(time * 1000),
      "message" => "firezone #{stream} #{event.log_id}",
      "firezone" => event
    })
  end

  @impl true
  def join_batch(encoded_events) do
    IO.iodata_to_binary(["[", Enum.intersperse(encoded_events, ","), "]"])
  end

  @impl true
  def post_batch(%Datadog.LogSink{} = sink, body) when is_binary(body) do
    [base_url: "https://http-intake.logs.#{sink.site}"]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # The intake never redirects; surface a redirect as the config error it is.
    |> Req.merge(
      url: "/api/v2/logs",
      headers: [
        {"dd-api-key", sink.api_key},
        {"content-type", "application/json"}
      ],
      redirect: false
    )
    |> Req.post(body: body)
  end

  @impl true
  def interpret(_sink, %Req.Response{status: 202}), do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "Datadog returned an HTTP #{status} redirect. Check that the site matches your " <>
      "organization's Datadog site."
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case body do
      %{"errors" => errors} when is_list(errors) and errors != [] ->
        "Datadog returned HTTP #{status}: #{format_errors(errors)}"

      _ ->
        "Datadog returned HTTP #{status}"
    end
  end

  defp format_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{"detail" => detail} -> detail
      %{"title" => title} -> title
      error when is_binary(error) -> error
      error -> inspect(error)
    end)
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
