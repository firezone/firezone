defmodule Portal.Sentinel.APIClient do
  @moduledoc """
  Azure Monitor Logs Ingestion API adapter for log sink delivery to
  Microsoft Sentinel.

  Firezone owns a multi-tenant Entra application; the customer admin-consents
  to create its service principal in their tenant and grants it the
  Monitoring Metrics Publisher role on their data collection rule. Each sync
  run acquires a client-credentials token against the customer tenant, then
  posts batches as JSON arrays to
  `{ingestion endpoint}/dataCollectionRules/{DCR immutable id}/streams/{stream name}`.
  Azure Monitor acknowledges accepted payloads with a 204 and caps requests
  at 1 MB.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.Sentinel

  @impl true
  def prepare(%Sentinel.LogSink{} = sink) do
    case fetch_access_token(sink) do
      {:ok, token} ->
        # Delivery runs prepare before any post_batch in the same process; the
        # token rides the process dictionary because the adapter contract has
        # no other per-run state.
        Process.put({__MODULE__, sink.id}, token)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def encode_event(_sink, stream, {time, event}) do
    JSON.encode!(%{
      "TimeGenerated" =>
        time |> Kernel.*(1000) |> round() |> DateTime.from_unix!(:millisecond),
      "Message" => "firezone #{stream} #{event.log_id}",
      "Stream" => "#{stream}",
      "Firezone" => event
    })
  end

  @impl true
  def join_batch(encoded_events) do
    IO.iodata_to_binary(["[", Enum.intersperse(encoded_events, ","), "]"])
  end

  @impl true
  def post_batch(%Sentinel.LogSink{} = sink, body) when is_binary(body) do
    token = Process.get({__MODULE__, sink.id})

    [base_url: sink.ingestion_endpoint]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # The ingestion endpoint never redirects; surface a redirect as the config error it is.
    |> Req.merge(
      url:
        "/dataCollectionRules/#{sink.dcr_immutable_id}/streams/#{sink.stream_name}" <>
          "?api-version=2023-01-01",
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"}
      ],
      redirect: false
    )
    |> Req.post(body: body)
  end

  @impl true
  def interpret(_sink, %Req.Response{status: status}) when status in 200..299, do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{status: 400}), do: :malformed_payload
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "Azure Monitor returned an HTTP #{status} redirect. Check that the ingestion endpoint " <>
      "is your data collection endpoint or the DCR's logs ingestion endpoint."
  end

  def format_status_error(%Req.Response{
        status: status,
        body: %{"error_description" => description}
      }) do
    detail = description |> String.split(~r/\r?\n/) |> List.first()

    "Microsoft Entra returned HTTP #{status}: #{detail} Ensure the tenant ID is correct " <>
      "and admin consent has been granted for the Firezone Sentinel Log Ingestion " <>
      "application in your tenant."
  end

  def format_status_error(%Req.Response{status: status, body: body})
      when status in [401, 403] do
    "Azure Monitor returned HTTP #{status}: #{azure_error_message(body) || "access denied"}. " <>
      "Grant the Firezone service principal the Monitoring Metrics Publisher role on the " <>
      "data collection rule; role assignments can take up to 30 minutes to propagate."
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case azure_error_message(body) do
      nil -> "Azure Monitor returned HTTP #{status}"
      message -> "Azure Monitor returned HTTP #{status}: #{message}"
    end
  end

  defp azure_error_message(%{"error" => %{"message" => message}}) when is_binary(message) do
    message
  end

  defp azure_error_message(%{"error" => error}) when is_binary(error), do: error
  defp azure_error_message(_body), do: nil

  defp fetch_access_token(sink) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    token_endpoint = "#{config[:token_base_url]}/#{sink.tenant_id}/oauth2/v2.0/token"

    payload =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "client_secret" => config[:client_secret],
        # Double slash per Microsoft's samples: audience "https://monitor.azure.com/" + "/.default".
        "scope" => "https://monitor.azure.com//.default",
        "grant_type" => "client_credentials"
      })

    result =
      Req.post(
        token_endpoint,
        [
          headers: [{"content-type", "application/x-www-form-urlencoded"}],
          body: payload,
          redirect: false
        ] ++ Keyword.fetch!(config, :req_opts)
      )

    case result do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %Req.Response{} = response} ->
        {:error, {:status, response}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
