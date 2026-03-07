defmodule Portal.AzureCommunicationServices do
  @moduledoc """
  Handles ACS Event Grid delivery reports for recipient and message-level email state.
  """

  alias Portal.EmailSuppression
  alias __MODULE__.Database

  @ignored_delivery_statuses MapSet.new(["Queued", "OutForDelivery", "Expanded"])

  def event_grid_webhook_secret do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:event_grid_webhook_secret)
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

  defp report_update_attrs(%{"deliveryStatus" => delivery_status} = data) do
    if MapSet.member?(@ignored_delivery_statuses, delivery_status) do
      :ignore
    else
      terminal_status_attrs(data)
    end
  end

  defp terminal_status_attrs(%{"deliveryStatus" => "Delivered"}) do
    %{status: :delivered, failure_code: nil, failure_message: nil, suppress?: false}
  end

  defp terminal_status_attrs(%{"deliveryStatus" => "Suppressed"} = data) do
    %{
      status: :suppressed,
      failure_code: "Suppressed",
      failure_message: data["deliveryStatusDetails"],
      suppress?: true
    }
  end

  defp terminal_status_attrs(%{"deliveryStatus" => "Bounced"} = data) do
    %{
      status: :bounced,
      failure_code: "Bounced",
      failure_message: data["deliveryStatusDetails"],
      suppress?: true
    }
  end

  defp terminal_status_attrs(%{"deliveryStatus" => delivery_status} = data) do
    details = data["deliveryStatusDetails"]

    cond do
      suppression_text?(delivery_status) or suppression_text?(details) ->
        %{
          status: :suppressed,
          failure_code: to_string(delivery_status),
          failure_message: details,
          suppress?: true
        }

      bounce_text?(delivery_status) or bounce_text?(details) ->
        %{
          status: :bounced,
          failure_code: to_string(delivery_status),
          failure_message: details,
          suppress?: true
        }

      true ->
        %{
          status: :failed,
          failure_code: to_string(delivery_status),
          failure_message: details,
          suppress?: false
        }
    end
  end

  defp suppression_text?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), "suppress")

  defp suppression_text?(_value), do: false

  defp bounce_text?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), "bounce")

  defp bounce_text?(_value), do: false

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
