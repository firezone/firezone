defmodule Portal.AzureCommunicationServices do
  @moduledoc """
  Handles ACS Event Grid delivery reports for recipient and message-level email state.
  """

  alias Portal.EmailSuppression
  alias __MODULE__.Database

  @ignored_delivery_statuses MapSet.new(["Expanded"])

  def event_grid_webhook_signing_secret do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:event_grid_webhook_signing_secret)
  end

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

  defp delivery_report(%{"data" => data}) when is_map(data) do
    with message_id when is_binary(message_id) <- data["messageId"],
         recipient when is_binary(recipient) <- data["recipient"],
         %{} = attrs <- report_update_attrs(data) do
      {:ok,
       Map.merge(attrs, %{
         message_id: message_id,
         email: EmailSuppression.normalize_email(recipient)
       })}
    else
      nil -> :ok
      :ignore -> :ok
      _ -> {:error, :invalid_delivery_report}
    end
  end

  defp delivery_report(_event), do: {:error, :invalid_delivery_report}

  defp report_update_attrs(%{"status" => status} = data) do
    if MapSet.member?(@ignored_delivery_statuses, status) do
      :ignore
    else
      details = extract_details(data["deliveryStatusDetails"])
      terminal_status_attrs(status, details)
    end
  end

  defp extract_details(%{"statusMessage" => msg}) when is_binary(msg), do: msg
  defp extract_details(details) when is_binary(details), do: details
  defp extract_details(_), do: nil

  defp terminal_status_attrs("Delivered", _details) do
    %{status: :delivered, failure_code: nil, failure_message: nil, suppress?: false}
  end

  defp terminal_status_attrs("Suppressed", details) do
    %{status: :suppressed, failure_code: "Suppressed", failure_message: details, suppress?: true}
  end

  defp terminal_status_attrs("Bounced", details) do
    %{status: :bounced, failure_code: "Bounced", failure_message: details, suppress?: true}
  end

  defp terminal_status_attrs("Quarantined", details) do
    %{
      status: :quarantined,
      failure_code: "Quarantined",
      failure_message: details,
      suppress?: true
    }
  end

  defp terminal_status_attrs("FilteredSpam", details) do
    %{
      status: :filtered_spam,
      failure_code: "FilteredSpam",
      failure_message: details,
      suppress?: true
    }
  end

  defp terminal_status_attrs(status, details) do
    %{
      status: :failed,
      failure_code: to_string(status),
      failure_message: details,
      suppress?: true
    }
  end

  defmodule Database do
    import Ecto.Query

    require Logger

    alias Portal.Safe
    alias Portal.{EmailSuppression, OutboundEmailDelivery, Repo}

    @db_opts [timeout: 20_000, pool_timeout: 20_000]

    def apply_delivery_report(report) do
      Safe.transact(
        fn ->
          with {:ok, update_result} <- update_delivery(report),
               :ok <- maybe_insert_suppression(update_result, report.suppress?, report.email) do
            {:ok, update_result}
          end
        end,
        @db_opts
      )
    end

    defp update_delivery(report) do
      {count, _} =
        from(d in OutboundEmailDelivery,
          where: d.message_id == ^report.message_id,
          where: d.email == ^report.email,
          where: d.status == :pending
        )
        |> Safe.unscoped(Repo)
        |> Safe.update_all(
          set: [
            status: report.status,
            failure_code: report.failure_code,
            failure_message: report.failure_message,
            updated_at: DateTime.utc_now()
          ]
        )

      case count do
        1 ->
          {:ok, :updated}

        0 ->
          Logger.info("Ignored ACS delivery report; no pending delivery found",
            message_id: report.message_id,
            email: report.email
          )

          {:ok, :ignored}
      end
    end

    defp maybe_insert_suppression(:ignored, _suppress?, _email), do: :ok
    defp maybe_insert_suppression(_result, false, _email), do: :ok

    defp maybe_insert_suppression(:updated, true, email) do
      Safe.insert_all(
        Repo,
        EmailSuppression,
        [%{email: email, inserted_at: DateTime.utc_now()}],
        Keyword.merge(
          @db_opts,
          on_conflict: :nothing,
          conflict_target: [:email]
        )
      )

      :ok
    end
  end
end
