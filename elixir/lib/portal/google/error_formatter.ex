defmodule Portal.Google.ErrorFormatter do
  @moduledoc """
  Google-specific error formatting for directory sync.

  Handles Google Workspace API errors and provides user-friendly messages.
  """

  @behaviour Portal.DirectorySync.ErrorFormatter

  alias Portal.DirectorySync.ErrorFormatter

  @impl true
  def classify_and_format(context) do
    case classify(context) do
      {:client_error, ctx} -> {:client_error, format(ctx)}
      {:transient, ctx} -> {:transient, format(ctx)}
    end
  end

  @impl true
  def format_generic_error(error) when is_exception(error) do
    Exception.message(error)
  end

  def format_generic_error(error) do
    inspect(error)
  end

  # Classification - determines error type

  # HTTP 4xx -> client_error (disable immediately)
  defp classify(%Req.Response{status: status} = resp) when status >= 400 and status < 500 do
    {:client_error, resp}
  end

  # HTTP 5xx -> transient
  defp classify(%Req.Response{} = resp) do
    {:transient, resp}
  end

  # Network errors -> transient
  defp classify(%Req.TransportError{} = err) do
    {:transient, err}
  end

  # String contexts with special prefixes -> client_error
  defp classify("validation: " <> _ = msg), do: {:client_error, msg}
  defp classify("scopes: " <> _ = msg), do: {:client_error, msg}
  defp classify("circuit_breaker: " <> _ = msg), do: {:client_error, msg}

  # nil context -> transient with generic message
  defp classify(nil), do: {:transient, nil}

  # Other string contexts -> transient
  defp classify(msg) when is_binary(msg), do: {:transient, msg}

  # Formatting - converts context to user-friendly message

  # Transport errors
  defp format(%Req.TransportError{} = err) do
    ErrorFormatter.format_transport_error(err)
  end

  # Error response with error object
  defp format(%Req.Response{status: status, body: %{"error" => error_obj}})
       when is_map(error_obj) do
    code = Map.get(error_obj, "code")
    message = Map.get(error_obj, "message")

    reason =
      case Map.get(error_obj, "errors") do
        [%{"reason" => r} | _] -> r
        _ -> nil
      end

    parts =
      [
        "HTTP #{status}",
        if(code && code != status, do: "Code: #{code}"),
        if(reason, do: "Reason: #{reason}"),
        if(message, do: message)
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " - ")
  end

  # Response with binary body
  defp format(%Req.Response{status: status, body: body}) when is_binary(body) do
    "HTTP #{status} - #{body}"
  end

  # Generic response
  defp format(%Req.Response{status: status}) do
    "Google API returned HTTP #{status}"
  end

  # nil context
  defp format(nil), do: "Unknown error occurred"

  # String context (pass through)
  defp format(msg) when is_binary(msg), do: msg
end
