defmodule Portal.Okta.ErrorHandler do
  @moduledoc """
  Handles Okta directory sync errors.

  Classifies errors, formats user-friendly messages, and updates directory state.
  """

  alias Portal.Okta
  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias __MODULE__.Database
  require Logger

  def handle(%Okta.SyncError{error: error}, directory_id) do
    type = classify(error)
    message = format(error)
    action(type, message, directory_id)
  end

  def handle(error, directory_id) do
    message = format_generic(error)
    action(:transient, message, directory_id)
  end

  defp format_generic(error) when is_exception(error), do: Exception.message(error)
  defp format_generic(error), do: inspect(error)

  # Classification

  defp classify(%Req.Response{status: status}) when status >= 400 and status < 500 do
    :client_error
  end

  defp classify(%Req.Response{}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient
  defp classify("validation: " <> _), do: :client_error
  defp classify("scopes: " <> _), do: :client_error
  defp classify("circuit_breaker: " <> _), do: :client_error
  defp classify(nil), do: :transient
  defp classify(msg) when is_binary(msg), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = err), do: SharedErrorHandler.format_transport_error(err)

  defp format(%Req.Response{status: status, body: body}) when is_map(body) do
    Okta.ErrorCodes.format_error(status, body)
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    Okta.ErrorCodes.format_error(status, body)
  end

  defp format(%Req.Response{status: status}) do
    Okta.ErrorCodes.format_error(status, nil)
  end

  defp format(nil), do: "Unknown error occurred"
  defp format(msg) when is_binary(msg), do: msg

  # Action

  defp action(type, message, directory_id) do
    now = DateTime.utc_now()

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: :okta,
          directory_id: directory_id
        )

        :ok

      directory ->
        do_update_directory(directory, type, message, now)
    end
  end

  defp do_update_directory(directory, :client_error, message, now) do
    Database.update_directory(directory, %{
      "errored_at" => now,
      "error_message" => message,
      "is_disabled" => true,
      "disabled_reason" => "Sync error",
      "is_verified" => false
    })
  end

  defp do_update_directory(directory, :transient, message, now) do
    errored_at = directory.errored_at || now
    hours_since_error = DateTime.diff(now, errored_at, :hour)
    should_disable = hours_since_error >= 24

    updates = %{
      "errored_at" => errored_at,
      "error_message" => message
    }

    updates =
      if should_disable do
        Map.merge(updates, %{
          "is_disabled" => true,
          "disabled_reason" => "Sync error",
          "is_verified" => false
        })
      else
        updates
      end

    Database.update_directory(directory, updates)
  end

  defmodule Database do
    @moduledoc false

    import Ecto.Query
    alias Portal.{Safe, Okta}

    def get_directory(directory_id) do
      from(d in Okta.Directory, where: d.id == ^directory_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(directory, attrs) do
      changeset =
        Ecto.Changeset.cast(directory, attrs, [
          :errored_at,
          :error_message,
          :is_disabled,
          :disabled_reason,
          :is_verified
        ])

      {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
    end
  end
end
