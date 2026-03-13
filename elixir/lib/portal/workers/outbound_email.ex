defmodule Portal.Workers.OutboundEmail do
  @moduledoc """
  Oban worker that submits a queued email using the secondary outbound adapter.
  """

  use Oban.Worker, queue: :outbound_emails, max_attempts: 3

  alias Portal.AzureCommunicationServices.APIClient
  alias Portal.Mailer
  alias __MODULE__.Database
  require Logger

  @secondary_snooze_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "request" => request}}) do
    with :ok <- ensure_secondary_adapter_configured(),
         :ok <- ensure_within_rate_limits() do
      request
      |> deserialize()
      |> maybe_put_acs_options()
      |> Mailer.deliver_secondary()
      |> persist_delivery_result(account_id, request)
    end
  end

  defp ensure_secondary_adapter_configured do
    if secondary_adapter_configured?() do
      :ok
    else
      Logger.debug("Secondary outbound adapter is not configured, snoozing email job")
      {:snooze, @secondary_snooze_seconds}
    end
  end

  defp ensure_within_rate_limits do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    per_minute = config[:rate_limit_per_minute]
    per_hour = config[:rate_limit_per_hour]

    with :ok <- check_rate_limit(:minute, per_minute),
         :ok <- check_rate_limit(:hour, per_hour) do
      :ok
    end
  end

  defp check_rate_limit(_window, limit) when not is_integer(limit) or limit <= 0, do: :ok

  defp check_rate_limit(window, limit) do
    {count, oldest_at} = Database.sent_window_stats(window)

    if count < limit do
      :ok
    else
      snooze_seconds = Database.snooze_seconds(window, oldest_at)

      Logger.warning("Outbound email rate limit reached, snoozing email job",
        window: window,
        limit: limit,
        snooze_seconds: snooze_seconds
      )

      {:snooze, snooze_seconds}
    end
  end

  defp persist_delivery_result({:ok, response}, account_id, request) do
    case response_message_id(response) do
      message_id when is_binary(message_id) ->
        case Mailer.insert_tracked_delivery(account_id, :later, message_id, request, response) do
          {:ok, _entry} ->
            :ok

          {:error, reason} ->
            Logger.error("Failed to persist tracked outbound email",
              account_id: account_id,
              message_id: message_id,
              reason: inspect(reason)
            )

            {:error, {:track_delivery, reason}}
        end

      nil ->
        handle_missing_message_id(account_id, response)
    end
  end

  defp persist_delivery_result({:error, {status, body}}, account_id, _request) do
    Logger.error("Queued email delivery failed",
      account_id: account_id,
      status: status,
      body: inspect(body)
    )

    if permanent_http_failure?(status) do
      {:discard, {:http_failure, status}}
    else
      {:error, {:http_failure, status, body}}
    end
  end

  defp persist_delivery_result({:error, reason}, account_id, _request) do
    Logger.error("Queued email delivery failed",
      account_id: account_id,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  defp handle_missing_message_id(account_id, response) do
    if APIClient.secondary_enabled?() do
      Logger.error("ACS queued email response did not include a message id",
        account_id: account_id,
        response: inspect(response)
      )

      {:discard, :missing_message_id}
    else
      :ok
    end
  end

  defp permanent_http_failure?(status) when is_integer(status),
    do: status in 400..499 and status != 429

  defp permanent_http_failure?(_status), do: false

  defp secondary_adapter_configured? do
    not is_nil(Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)[:adapter])
  end

  defp deserialize(
         %{
           "from" => from,
           "subject" => subject,
           "html_body" => html_body,
           "text_body" => text_body
         } = request
       ) do
    Swoosh.Email.new()
    |> maybe_put_recipients(:to, request["to"] || [])
    |> maybe_put_recipients(:cc, request["cc"] || [])
    |> maybe_put_recipients(:bcc, request["bcc"] || [])
    |> Swoosh.Email.from({from["name"], from["address"]})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(text_body)
  end

  defp maybe_put_recipients(email, _field, []), do: email

  defp maybe_put_recipients(email, field, recipients) do
    mapped =
      Enum.map(recipients, fn %{"name" => name, "address" => address} -> {name, address} end)

    case field do
      :to -> Swoosh.Email.to(email, mapped)
      :cc -> Swoosh.Email.cc(email, mapped)
      :bcc -> Swoosh.Email.bcc(email, mapped)
    end
  end

  defp maybe_put_acs_options(%Swoosh.Email{} = email) do
    if APIClient.secondary_enabled?() do
      APIClient.put_secondary_client_options(email)
    else
      email
    end
  end

  defp response_message_id(response) when is_map(response), do: response[:id] || response["id"]
  defp response_message_id(_response), do: nil

  defmodule Database do
    import Ecto.Query

    alias Portal.OutboundEmail
    alias Portal.Safe

    @minute_window_seconds 60
    @hour_window_seconds 3600

    def sent_window_stats(window) do
      {seconds, repo} = window_config(window)

      query =
        from(e in OutboundEmail,
          where: e.priority == :later,
          where: e.inserted_at > ago(^seconds, "second")
        )

      scoped = Safe.unscoped(query, repo)

      {
        Safe.aggregate(scoped, :count),
        Safe.aggregate(scoped, :min, :inserted_at)
      }
    end

    def snooze_seconds(window, nil), do: default_snooze_seconds(window)

    def snooze_seconds(window, %DateTime{} = oldest_at) do
      window_seconds = window_size(window)
      elapsed_seconds = DateTime.diff(DateTime.utc_now(), oldest_at, :second)
      max(1, window_seconds - elapsed_seconds + 1)
    end

    defp window_config(:minute), do: {@minute_window_seconds, :replica}
    defp window_config(:hour), do: {@hour_window_seconds, :replica}

    defp window_size(:minute), do: @minute_window_seconds
    defp window_size(:hour), do: @hour_window_seconds

    defp default_snooze_seconds(:minute), do: @minute_window_seconds
    defp default_snooze_seconds(:hour), do: @hour_window_seconds
  end
end
