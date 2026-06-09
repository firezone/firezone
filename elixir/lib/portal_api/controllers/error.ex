defmodule PortalAPI.Error do
  @moduledoc """
  Centralized error handling for API controllers.

  Provides explicit `handle/2` functions for all error cases,
  avoiding action_fallback macros which can break stack traces.

  All responses follow RFC 9457 (Problem Details for HTTP APIs) via
  `PortalAPI.ProblemDetails`.
  """
  alias PortalAPI.ProblemDetails

  require Logger

  @spec handle(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle(conn, {:error, :not_found}) do
    ProblemDetails.send(conn, 404, "The requested resource could not be found.")
  end

  def handle(conn, {:error, :unauthorized}) do
    ProblemDetails.send(conn, 401, "Authentication credentials were missing or invalid.")
  end

  def handle(conn, {:error, :bad_request}) do
    ProblemDetails.send(conn, 400, "The request could not be processed.")
  end

  def handle(conn, {:error, :bad_request, reason: reason}) do
    ProblemDetails.send(conn, 400, reason)
  end

  def handle(conn, {:error, :invalid_cursor}) do
    ProblemDetails.send(conn, 400, "Invalid page cursor")
  end

  def handle(conn, {:error, :forbidden}) do
    ProblemDetails.send(conn, 403, "You do not have permission to perform this action.")
  end

  def handle(conn, {:error, :forbidden, reason: reason}) do
    ProblemDetails.send(conn, 403, reason)
  end

  def handle(conn, {:error, %Ecto.Changeset{} = changeset}) do
    ProblemDetails.send(conn, 422, "The request body failed validation.", %{
      validation_errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    })
  end

  def handle(conn, error) do
    Logger.error("Unhandled API error", error: inspect(error))

    ProblemDetails.send(conn, 500, "An unexpected error occurred.")
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
