defmodule Portal.Analytics.GoogleAds do
  @moduledoc """
  Imports account conversions with the Google Data Manager API.

  Google destinations use numeric import conversion action IDs, not browser tag
  labels. Only hashed email enters the job; federation settings stay in runtime config.
  https://developers.google.com/data-manager/api/devguides/events/send-events
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:payload]]

  alias Portal.Analytics
  require Logger

  def enqueue(account, email, event_type, opts) do
    attribution = account.metadata.marketing_attribution
    config = config()
    action_id = conversion_action_id(config, event_type)

    if configured?(config) and present?(action_id) and
         Analytics.marketing_allowed?(attribution) and present?(email) do
      event = %{
        "transactionId" => opts[:id],
        "eventTimestamp" => opts[:timestamp_ms] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
        "eventSource" => "WEB",
        "userData" => %{"userIdentifiers" => [%{"emailAddress" => hash_email(email)}]},
        "consent" => %{"adUserData" => "CONSENT_GRANTED", "adPersonalization" => "CONSENT_GRANTED"}
      }

      identifiers = Map.take(attribution, ~w[gclid gbraid wbraid])
      event = if map_size(identifiers) > 0, do: Map.put(event, "adIdentifiers", identifiers), else: event

      destination = destination(config, action_id)

      payload = %{"destinations" => [destination], "events" => [event], "encoding" => "HEX"}

      case new(%{"account_id" => account.id, "payload" => payload}) |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, _} -> {:error, :conversion_enqueue_failed}
      end
    else
      :ok
    end
  rescue
    _ ->
      Logger.warning("Could not enqueue Google Ads conversion", event: event_type)
      {:error, :conversion_enqueue_failed}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "payload" => payload}}) do
    if Analytics.delivery_allowed?(account_id), do: deliver(payload), else: :ok
  end

  @doc false
  def deliver(payload) do
    config = config()

    if configured?(config) do
      with {:ok, token} <- access_token(config) do
        send_payload(payload, token, config)
      end
    else
      :ok
    end
  end

  defp send_payload(payload, token, config) do
    opts = [auth: {:bearer, token}, json: payload] ++ config[:req_opts]

    case Req.post(config[:endpoint], opts) do
      {:ok, %Req.Response{status: status, body: %{"requestId" => request_id} = body}}
      when status in 200..299 ->
        # Ingestion is asynchronous. Keep the request ID and safe warning details.
        Logger.info("Google Ads conversion accepted", request_id: request_id)

        if body["fieldWarnings"] not in [nil, []] do
          Logger.warning("Google Ads conversion has field warnings", request_id: request_id,
            warnings: field_warnings(body))
        end

        args = %{
          "request_id" => request_id,
          "transaction_id" => get_in(payload, ["events", Access.at(0), "transactionId"])
        }
        case __MODULE__.Diagnostics.new(args, schedule_in: 1800, meta: %{field_warnings: field_warnings(body)}) |> Oban.insert() do
          {:ok, _job} -> :ok
          {:error, _} -> {:error, :diagnostics_enqueue_failed}
        end

      result -> request_error(result)
    end
  end

  defp field_warnings(body), do: Enum.map(body["fieldWarnings"] || [], &Map.take(&1, ["reason", "field"]))

  @doc "Retrieve processing diagnostics without sending another conversion."
  def request_status(request_id) when is_binary(request_id) do
    config = config()

    with {:ok, token} <- access_token(config) do
      endpoint = URI.merge(config[:endpoint], "./requestStatus:retrieve") |> URI.to_string()
      case Req.get(endpoint, [auth: {:bearer, token}, params: [requestId: request_id]] ++ config[:req_opts]) do
        {:ok, %Req.Response{status: 200, body: %{"requestStatusPerDestination" => statuses}}} when is_list(statuses) ->
          {:ok, Enum.map(statuses, &diagnostic_summary/1)}
        {:ok, %Req.Response{status: 404}} -> {:error, :diagnostics_not_ready}
        result -> request_error(result)
      end
    end
  end

  # Persist only aggregate diagnostics, never response messages or user identifiers.
  defp diagnostic_summary(status) do
    %{
      "status" => status["requestStatus"],
      "errors" => diagnostic_counts(get_in(status, ["errorInfo", "errorCounts"])),
      "warnings" => diagnostic_counts(get_in(status, ["warningInfo", "warningCounts"]))
    }
  end

  defp diagnostic_counts(nil), do: []
  defp diagnostic_counts(counts), do: Enum.map(counts, &Map.take(&1, ["reason", "recordCount"]))

  @doc "Validate both configured destinations through the production identity chain without importing events."
  def validate_configuration do
    config = config()

    with true <- configured?(config) || {:error, :not_configured},
         {:ok, token} <- access_token(config) do
      Enum.map([:registration_conversion_action_id, :subscription_conversion_action_id], fn key ->
        {key, validate_action(config, config[key], token)}
      end)
    end
  end

  defp validate_action(config, action_id, token) do
    if present?(action_id) do
      payload = %{
        "validateOnly" => true, "encoding" => "HEX", "destinations" => [destination(config, action_id)],
        "events" => [%{
          "transactionId" => "configuration_validation",
          "eventTimestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "eventSource" => "WEB",
          "userData" => %{"userIdentifiers" => [%{"emailAddress" => hash_email("validation@example.com")}]},
          "consent" => %{"adUserData" => "CONSENT_GRANTED", "adPersonalization" => "CONSENT_GRANTED"}
        }]
      }
      case Req.post(config[:endpoint], [auth: {:bearer, token}, json: payload] ++ config[:req_opts]) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          {:ok, %{field_warnings: field_warnings(body)}}
        result -> request_error(result)
      end
    else
      {:error, :missing_conversion_action}
    end
  end

  defp destination(config, action_id) do
    destination = %{
      "operatingAccount" => %{"accountType" => "GOOGLE_ADS", "accountId" => config[:customer_id]},
      "productDestinationId" => action_id
    }

    if present?(config[:login_customer_id]) do
      Map.put(destination, "loginAccount", %{
        "accountType" => "GOOGLE_ADS", "accountId" => config[:login_customer_id]
      })
    else
      destination
    end
  end

  defp access_token(config) do
    identity = Keyword.take(config, [:service_account_email, :workload_identity_provider, :workload_identity_audience])

    case Portal.Google.APIClient.get_service_account_access_token(
           identity, "https://www.googleapis.com/auth/datamanager"
         ) do
      {:ok, token} -> {:ok, token}
      # Do not persist HTTP response bodies or identity tokens in Oban errors.
      {:error, {_stage, %Req.Response{status: status}}} ->
        request_error({:ok, %Req.Response{status: status}})
      {:error, _} -> {:error, :authentication_failed}
    end
  end

  defp request_error({:ok, %Req.Response{status: status}}) when status in [408, 429] or status >= 500,
    do: {:error, {:http_status, status}}
  defp request_error({:ok, %Req.Response{status: status}}) when status in 400..499,
    do: {:cancel, {:http_status, status}}
  defp request_error({:ok, %Req.Response{}}), do: {:error, :unexpected_response}
  defp request_error({:error, _}), do: {:error, :request_failed}

  # Data Manager normalizes Gmail aliases before hashing; OpenAI does not.
  # https://developers.google.com/data-manager/api/devguides/concepts/formatting
  def hash_email(email) do
    normalized = email |> String.downcase() |> String.replace(~r/\s/u, "")
    normalized =
      case String.split(normalized, "@", parts: 2) do
        [local, domain] when domain in ["gmail.com", "googlemail.com"] ->
          local = local |> String.split("+", parts: 2) |> hd() |> String.replace(".", "")
          local <> "@" <> domain
        _ -> normalized
      end
    Analytics.hash_email(normalized)
  end

  defp conversion_action_id(config, "registration_completed"), do: config[:registration_conversion_action_id]
  defp conversion_action_id(config, "subscription_created"), do: config[:subscription_conversion_action_id]
  defp conversion_action_id(_config, _event_type), do: nil

  defp configured?(config),
    do: Enum.all?([:customer_id, :service_account_email, :workload_identity_provider, :workload_identity_audience], &present?(config[&1]))

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: Portal.Config.get_env(:portal, __MODULE__, [])
end
