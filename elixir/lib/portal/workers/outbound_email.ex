defmodule Portal.Workers.OutboundEmail do
  @moduledoc """
  Oban worker that submits queued emails using the secondary outbound adapter.

  Runs every minute. Sends up to `outbound_email_rate_limit_per_minute` emails per
  run, respecting an `outbound_email_rate_limit_per_hour` global cap. Only :later
  emails are subject to this worker and these quotas. Set either limit to 0 to
  disable it.
  """

  use Oban.Worker,
    queue: :outbound_emails,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Portal.AzureCommunicationServices.APIClient
  alias Portal.OutboundEmail
  alias Portal.Mailer
  alias __MODULE__.Database
  require Logger

  @unlimited_batch_size 1_000

  @impl Oban.Worker
  def perform(_job) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    per_minute = config[:rate_limit_per_minute]
    per_hour = config[:rate_limit_per_hour]

    remaining_hour = if per_hour > 0, do: per_hour - Database.count_sent_last_hour(), else: nil

    if remaining_hour != nil and remaining_hour <= 0 do
      Logger.warning("Outbound email hourly rate limit reached, skipping batch")
      :ok
    else
      remaining_minute =
        if per_minute > 0, do: per_minute - Database.count_sent_last_minute(), else: nil

      batch_size = min_of(remaining_minute, remaining_hour)

      if batch_size <= 0 do
        Logger.debug("Outbound email per-minute rate limit reached, skipping batch")
        :ok
      else
        Database.fetch_pending(batch_size)
        |> Enum.each(&process_email/1)

        :ok
      end
    end
  end

  defp min_of(nil, nil), do: @unlimited_batch_size
  defp min_of(nil, b), do: b
  defp min_of(a, nil), do: a
  defp min_of(a, b), do: min(a, b)

  defp process_email(%OutboundEmail{} = entry) do
    Database.mark_attempted(entry)
    email = prepare_email(entry)

    case Mailer.deliver_secondary(email) do
      {:ok, response} ->
        handle_successful_submission(entry, response)

      {:error, {status, body}} ->
        Logger.error("Queued email delivery failed",
          id: entry.id,
          account_id: entry.account_id,
          status: status,
          body: inspect(body)
        )

        Database.mark_send_failure(entry, %{"status" => status, "body" => inspect(body)})

      {:error, reason} ->
        Logger.error("Queued email delivery failed",
          id: entry.id,
          account_id: entry.account_id,
          reason: inspect(reason)
        )

        Database.mark_send_failure(entry, %{"reason" => inspect(reason)})
    end
  end

  defp handle_successful_submission(%OutboundEmail{} = entry, response) do
    case response_message_id(response) do
      nil -> handle_missing_message_id(entry, response)
      message_id -> Database.mark_running(entry, response, message_id)
    end
  end

  defp handle_missing_message_id(%OutboundEmail{} = entry, response) do
    if APIClient.enabled?() do
      Logger.error("Queued email running without ACS message id",
        id: entry.id,
        account_id: entry.account_id,
        response: inspect(response)
      )

      Database.mark_send_failure(
        entry,
        %{"reason" => "missing_message_id", "response" => inspect(response)}
      )
    else
      Database.mark_running(entry, response, nil)
    end
  end

  defp prepare_email(%OutboundEmail{} = entry) do
    entry.request
    |> deserialize()
    |> maybe_put_acs_options()
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
    mapped = Enum.map(recipients, fn %{"name" => n, "address" => a} -> {n, a} end)

    case field do
      :to -> Swoosh.Email.to(email, mapped)
      :cc -> Swoosh.Email.cc(email, mapped)
      :bcc -> Swoosh.Email.bcc(email, mapped)
    end
  end

  defp maybe_put_acs_options(%Swoosh.Email{} = email) do
    if APIClient.enabled?() do
      email
      |> APIClient.put_client_options()
    else
      email
    end
  end

  defp response_message_id(response) when is_map(response), do: response[:id] || response["id"]
  defp response_message_id(_response), do: nil

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def fetch_pending(limit) do
      from(e in OutboundEmail,
        where: e.priority == :later,
        where: e.status in [:pending, :errored],
        where: is_nil(e.last_attempted_at) or e.last_attempted_at < ago(5, "minute"),
        order_by: [asc: e.inserted_at],
        limit: ^limit
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def count_sent_last_hour do
      from(e in OutboundEmail,
        where: e.priority == :later,
        where: e.last_attempted_at > ago(1, "hour"),
        where: e.status in [:running, :succeeded] or not is_nil(e.message_id)
      )
      |> Safe.unscoped(:replica)
      |> Safe.aggregate(:count)
    end

    def count_sent_last_minute do
      from(e in OutboundEmail,
        where: e.priority == :later,
        where: e.last_attempted_at > ago(1, "minute"),
        where: e.status in [:running, :succeeded] or not is_nil(e.message_id)
      )
      |> Safe.unscoped(:replica)
      |> Safe.aggregate(:count)
    end

    def mark_attempted(%OutboundEmail{} = entry) do
      entry
      |> Ecto.Changeset.change(last_attempted_at: DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.update()
    end

    def mark_running(%OutboundEmail{} = entry, response, message_id) do
      entry
      |> Ecto.Changeset.change(
        status: :running,
        response: normalize_response(response),
        message_id: message_id,
        failed_at: nil
      )
      |> Safe.unscoped()
      |> Safe.update()
    end

    def mark_send_failure(%OutboundEmail{} = entry, response) do
      entry
      |> Ecto.Changeset.change(
        status: :errored,
        response: normalize_response(response),
        message_id: nil
      )
      |> Safe.unscoped()
      |> Safe.update()
    end

    defp normalize_response(response) when is_map(response) do
      response
      |> Enum.map(fn {key, value} -> {to_string(key), normalize_response(value)} end)
      |> Map.new()
    end

    defp normalize_response(response) when is_list(response),
      do: Enum.map(response, &normalize_response/1)

    defp normalize_response(response), do: response
  end
end
