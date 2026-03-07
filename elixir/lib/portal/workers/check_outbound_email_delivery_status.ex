defmodule Portal.Workers.CheckOutboundEmailDeliveryStatus do
  @moduledoc """
  Oban worker that polls queued ACS email operations.
  """

  use Oban.Worker,
    queue: :outbound_emails,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Portal.AzureCommunicationServices.APIClient
  alias Portal.OutboundEmail
  alias __MODULE__.Database
  require Logger

  @batch_size 100

  @impl Oban.Worker
  def perform(_job) do
    if APIClient.enabled?() do
      Database.fetch_inflight(@batch_size)
      |> Enum.each(&refresh_status/1)
    end

    :ok
  end

  defp refresh_status(%OutboundEmail{} = entry) do
    case APIClient.fetch_delivery_state(entry.message_id) do
      {:ok, %{state: :processing, operation: operation}} ->
        Database.update_tracking(entry, operation)

      {:ok, %{state: :succeeded, operation: operation}} ->
        Database.mark_succeeded(entry, operation)

      {:ok, %{state: :failed, operation: operation}} ->
        Database.mark_failed(entry, operation)

      {:error, %Req.Response{} = response} ->
        Logger.error("Failed to poll ACS email delivery state",
          id: entry.id,
          account_id: entry.account_id,
          status: response.status,
          body: inspect(response.body)
        )

      {:error, reason} ->
        Logger.error("Failed to poll ACS email delivery state",
          id: entry.id,
          account_id: entry.account_id,
          reason: inspect(reason)
        )
    end
  end

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def fetch_inflight(limit) do
      from(e in OutboundEmail,
        where: e.priority == :later,
        where: e.status == :running,
        where: not is_nil(e.message_id),
        order_by: [asc: e.last_attempted_at],
        limit: ^limit
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def update_tracking(%OutboundEmail{} = entry, operation) do
      entry
      |> Ecto.Changeset.change(response: merge_response(entry.response, operation))
      |> Safe.unscoped()
      |> Safe.update()
    end

    def mark_succeeded(%OutboundEmail{} = entry, operation) do
      entry
      |> Ecto.Changeset.change(
        status: :succeeded,
        failed_at: nil,
        response: merge_response(entry.response, operation, "Succeeded")
      )
      |> Safe.unscoped()
      |> Safe.update()
    end

    def mark_failed(%OutboundEmail{} = entry, operation) do
      entry
      |> Ecto.Changeset.change(
        status: :failed,
        failed_at: DateTime.utc_now(),
        response: merge_response(entry.response, operation, "Failed")
      )
      |> Safe.unscoped()
      |> Safe.update()
    end

    defp merge_response(existing, operation, delivery_state \\ nil) do
      existing
      |> normalize_response()
      |> Map.put("operation", normalize_response(operation))
      |> maybe_put("delivery_state", delivery_state)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
