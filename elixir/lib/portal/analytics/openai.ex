defmodule Portal.Analytics.OpenAI do
  @moduledoc """
  Sends account conversions to the OpenAI Conversions API.

  https://developers.openai.com/ads/conversions-api
  Jobs contain only hashed email and reuse their event ID and timestamp on retries.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:event]]

  alias Portal.Analytics

  def enabled? do
    key = config()[:api_key]
    is_binary(key) and String.trim(key) != ""
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "event" => event}}) do
    case Analytics.Database.account(account_id) do
      %{metadata: %{marketing_attribution: attribution}} ->
        if Analytics.marketing_allowed?(attribution), do: deliver(event), else: :ok

      _ ->
        :ok
    end
  end

  @doc false
  def deliver(event) do
    if enabled?() do
      config = config()

      opts = [
        params: [pid: Keyword.fetch!(config, :pixel_id)],
        auth: {:bearer, Keyword.fetch!(config, :api_key)},
        json: %{integration_source: "firezone-portal", events: [event]}
      ]

      case Req.post(Keyword.fetch!(config, :endpoint), opts ++ config[:req_opts]) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} when status in [408, 429] or status >= 500 ->
          {:error, {:http_status, status}}
        {:ok, %Req.Response{status: status}} -> {:cancel, {:http_status, status}}
        {:error, _reason} -> {:error, :request_failed}
      end
    else
      :ok
    end
  end

  defp config, do: Portal.Config.fetch_env!(:portal, __MODULE__)
end
