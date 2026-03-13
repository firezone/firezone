defmodule Portal.AzureCommunicationServices do
  @moduledoc """
  Handles ACS Event Grid delivery reports for recipient and message-level email state.
  """

  alias Portal.EmailSuppression
  alias __MODULE__.Database

  @ignored_delivery_statuses MapSet.new(["Queued", "OutForDelivery", "Expanded"])

  def fetch_event_grid_webhook_secret! do
    fetch_config!(:event_grid_webhook_secret)
  end

  def event_grid_webhook_secret, do: fetch_event_grid_webhook_secret!()

  def handle_event_grid_events(events) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case handle_event(event) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp handle_event(
         %{"eventType" => "Microsoft.Communication.EmailDeliveryReportReceived"} = event
       ) do
    with {:ok, report} <- delivery_report(event),
         {:ok, _result} <- Database.apply_delivery_report(report) do
      :ok
    end
  end

  defp handle_event(_event), do: :ok

  defp delivery_report(%{"data" => data, "eventTime" => event_time}) when is_map(data) do
    with message_id when is_binary(message_id) <- data["messageId"],
         recipient when is_binary(recipient) <- data["recipient"],
         {:ok, occurred_at} <- parse_event_time(event_time),
         {:ok, attrs} <- recipient_update_attrs(data) do
      {:ok,
       Map.merge(attrs, %{
         message_id: message_id,
         email: EmailSuppression.normalize_email(recipient),
         occurred_at: occurred_at
       })}
    else
      nil -> :ok
      :ignore -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_delivery_report}
    end
  end

  defp delivery_report(_event), do: {:error, :invalid_delivery_report}

  defp recipient_update_attrs(%{"deliveryStatus" => delivery_status} = data) do
    if MapSet.member?(@ignored_delivery_statuses, delivery_status) do
      _ = data
      :ignore
    else
      recipient_update_attrs_for_terminal_status(data)
    end
  end

  defp recipient_update_attrs_for_terminal_status(%{"deliveryStatus" => "Delivered"}) do
    {:ok, %{status: :delivered, failure_code: nil, failure_message: nil, suppress?: false}}
  end

  defp recipient_update_attrs_for_terminal_status(%{"deliveryStatus" => "Suppressed"} = data) do
    {:ok,
     %{
       status: :suppressed,
       failure_code: "Suppressed",
       failure_message: data["deliveryStatusDetails"],
       suppress?: true
     }}
  end

  defp recipient_update_attrs_for_terminal_status(%{"deliveryStatus" => "Bounced"} = data) do
    {:ok,
     %{
       status: :bounced,
       failure_code: "Bounced",
       failure_message: data["deliveryStatusDetails"],
       suppress?: true
     }}
  end

  defp recipient_update_attrs_for_terminal_status(%{"deliveryStatus" => delivery_status} = data) do
    details = data["deliveryStatusDetails"]

    cond do
      suppression_text?(delivery_status) or suppression_text?(details) ->
        {:ok,
         %{
           status: :suppressed,
           failure_code: to_string(delivery_status),
           failure_message: details,
           suppress?: true
         }}

      bounce_text?(delivery_status) or bounce_text?(details) ->
        {:ok,
         %{
           status: :bounced,
           failure_code: to_string(delivery_status),
           failure_message: details,
           suppress?: true
         }}

      true ->
        {:ok,
         %{
           status: :failed,
           failure_code: to_string(delivery_status),
           failure_message: details,
           suppress?: false
         }}
    end
  end

  defp suppression_text?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), "suppress")

  defp suppression_text?(_value), do: false

  defp bounce_text?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), "bounce")

  defp bounce_text?(_value), do: false

  defp parse_event_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}}

      _ ->
        {:error, :invalid_event_time}
    end
  end

  defp parse_event_time(_value), do: {:error, :invalid_event_time}

  defp fetch_config!(key) do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(key)
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe
    alias Portal.{EmailSuppression, OutboundEmail, OutboundEmailRecipient, Repo}

    @db_opts [timeout: 20_000, pool_timeout: 20_000]
    @failed_recipient_statuses [:bounced, :suppressed, :failed]

    def apply_delivery_report(report) do
      Safe.transact(
        fn ->
          with {:ok, entry} <- fetch_entry(report.message_id),
               :ok <- ensure_recipient_exists(entry, report.email),
               {:ok, update_result} <- update_recipient(entry, report),
               {:ok, _suppression_result} <-
                 maybe_insert_suppression(
                   update_result,
                   report.suppress?,
                   report.email,
                   report.occurred_at
                 ),
               {:ok, _entry_result} <-
                 maybe_roll_up_entry(entry, update_result, report.occurred_at) do
            {:ok, update_result}
          end
        end,
        @db_opts
      )
    end

    defp fetch_entry(message_id) do
      query = from(e in OutboundEmail, where: e.message_id == ^message_id)

      query
      |> Safe.unscoped(Repo)
      |> Safe.one()
      |> case do
        nil -> {:error, {:unknown_message_id, message_id}}
        entry -> {:ok, entry}
      end
    end

    defp ensure_recipient_exists(entry, email) do
      query =
        from(r in OutboundEmailRecipient,
          where: r.account_id == ^entry.account_id,
          where: r.message_id == ^entry.message_id,
          where: r.email == ^email
        )

      if Safe.unscoped(query, Repo) |> Safe.exists?() do
        :ok
      else
        {:error, {:unknown_recipient, entry.message_id, email}}
      end
    end

    defp update_recipient(entry, report) do
      attrs = [
        status: report.status,
        last_event_at: report.occurred_at,
        failure_code: report.failure_code,
        failure_message: report.failure_message,
        updated_at: report.occurred_at
      ]

      query =
        from(r in OutboundEmailRecipient,
          where: r.account_id == ^entry.account_id,
          where: r.message_id == ^entry.message_id,
          where: r.email == ^report.email,
          where: is_nil(r.last_event_at) or r.last_event_at <= ^report.occurred_at
        )

      {count, _result} =
        query
        |> Safe.unscoped(Repo)
        |> Safe.update_all(set: attrs)

      case count do
        1 -> {:ok, :updated}
        0 -> {:ok, :stale}
      end
    end

    defp maybe_insert_suppression(:stale, _suppress?, _email, _occurred_at), do: {:ok, :skipped}

    defp maybe_insert_suppression(_result, false, _email, _occurred_at), do: {:ok, :skipped}

    defp maybe_insert_suppression(:updated, true, email, occurred_at) do
      Safe.insert_all(
        Repo,
        EmailSuppression,
        [%{email: email, inserted_at: occurred_at}],
        Keyword.merge(
          @db_opts,
          on_conflict: :nothing,
          conflict_target: [:email]
        )
      )
      |> then(fn result -> {:ok, result} end)
    end

    defp maybe_roll_up_entry(_entry, :stale, _occurred_at), do: {:ok, :skipped}

    defp maybe_roll_up_entry(entry, :updated, occurred_at) do
      status_counts = recipient_status_counts(entry)

      cond do
        status_counts.pending > 0 ->
          update_entry(entry, :running, nil, status_counts)

        status_counts.failed > 0 ->
          update_entry(entry, :failed, failed_at(entry, occurred_at), status_counts)

        true ->
          update_entry(entry, :succeeded, nil, status_counts)
      end
    end

    defp recipient_status_counts(entry) do
      base_query =
        from(r in OutboundEmailRecipient,
          where: r.account_id == ^entry.account_id,
          where: r.message_id == ^entry.message_id
        )

      %{
        pending:
          base_query
          |> where([r], r.status == :pending)
          |> Safe.unscoped(Repo)
          |> Safe.aggregate(:count),
        failed:
          base_query
          |> where([r], r.status in ^@failed_recipient_statuses)
          |> Safe.unscoped(Repo)
          |> Safe.aggregate(:count)
      }
    end

    defp update_entry(entry, status, failed_at, status_counts) do
      response =
        entry.response
        |> normalize_response()
        |> Map.put("delivery_state", delivery_state(status))
        |> Map.put("recipient_counts", %{
          "pending" => status_counts.pending,
          "failed" => status_counts.failed
        })

      entry
      |> Ecto.Changeset.change(status: status, failed_at: failed_at, response: response)
      |> Safe.unscoped()
      |> Safe.update()
    end

    defp delivery_state(:running), do: "Running"
    defp delivery_state(:succeeded), do: "Succeeded"
    defp delivery_state(:failed), do: "Failed"

    defp failed_at(entry, fallback) do
      query =
        from(r in OutboundEmailRecipient,
          where: r.account_id == ^entry.account_id,
          where: r.message_id == ^entry.message_id,
          where: r.status in ^@failed_recipient_statuses
        )

      query
      |> Safe.unscoped(Repo)
      |> Safe.aggregate(:max, :last_event_at)
      |> case do
        nil -> fallback
        datetime -> datetime
      end
    end

    defp normalize_response(nil), do: %{}

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
