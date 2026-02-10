defmodule Portal.Entra.ErrorHandler do
  @moduledoc """
  Handles Entra directory sync errors.

  Classifies errors, formats user-friendly messages, and updates directory state.
  """

  alias Portal.Entra
  alias Portal.DirectorySync.ErrorHandler, as: SharedErrorHandler
  alias __MODULE__.Database
  require Logger

  def handle(%Entra.SyncError{error: error}, directory_id) do
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

  defp classify(%Req.Response{status: status} = _resp) when status >= 400 and status < 500 do
    :client_error
  end

  defp classify(%Req.Response{}), do: :transient

  defp classify({:batch_all_failed, status, _body}) when status >= 400 and status < 500 do
    :client_error
  end

  defp classify({:batch_all_failed, _status, _body}), do: :transient

  defp classify({:batch_request_failed, status, _body}) when status >= 400 and status < 500 do
    :client_error
  end

  defp classify({:batch_request_failed, _status, _body}), do: :transient
  defp classify(%Req.TransportError{}), do: :transient

  defp classify({tag, _}) when tag in [:validation, :scopes, :circuit_breaker, :consent_revoked],
    do: :client_error

  defp classify(nil), do: :transient
  defp classify(msg) when is_binary(msg), do: :transient

  # Formatting

  defp format(%Req.TransportError{} = err), do: SharedErrorHandler.format_transport_error(err)

  defp format(%Req.Response{status: 403, body: %{"error" => error_obj}}) do
    code = Map.get(error_obj, "code")

    base_message =
      case code do
        "Authorization_RequestDenied" -> "Insufficient permissions"
        "Forbidden" -> "Access forbidden"
        _ -> "Permission denied"
      end

    "#{base_message}. Please verify the Firezone Directory Sync app has the required permissions " <>
      "(Directory.Read.All, User.Read.All, and Application.Read.All) in Microsoft Entra and re-grant admin consent."
  end

  defp format(%Req.Response{status: 401, body: %{"error" => _error_obj}}) do
    "Authentication failed. The app credentials may have expired or been revoked. " <>
      "Please re-grant admin consent in Microsoft Entra."
  end

  defp format(%Req.Response{status: status, body: %{"error" => error_obj}}) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")
    inner_code = get_in(error_obj, ["innerError", "code"])

    parts =
      [
        "HTTP #{status}",
        if(code, do: "Code: #{code}"),
        if(inner_code && inner_code != code, do: "Inner Code: #{inner_code}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  defp format(%Req.Response{status: 403}) do
    "Permission denied. Please verify the Firezone Directory Sync app has the required permissions " <>
      "in Microsoft Entra and re-grant admin consent."
  end

  defp format(%Req.Response{status: 401}) do
    "Authentication failed. Please re-grant admin consent in Microsoft Entra."
  end

  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  defp format(%Req.Response{status: status}), do: "Entra API returned HTTP #{status}"

  defp format({tag, status, body}) when tag in [:batch_all_failed, :batch_request_failed] do
    format(%Req.Response{status: status, body: body})
  end

  defp format({_tag, msg}) when is_binary(msg), do: msg
  defp format(nil), do: "Unknown error occurred"
  defp format(msg) when is_binary(msg), do: msg

  # Action

  defp action(type, message, directory_id) do
    now = DateTime.utc_now()

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Directory not found, skipping error update",
          provider: :entra,
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
    alias Portal.{Safe, Entra}

    def get_directory(directory_id) do
      from(d in Entra.Directory, where: d.id == ^directory_id)
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
