defmodule PortalAPI.Plugs.RescueRouterErrors do
  @moduledoc """
  Dispatches to `PortalAPI.Router` and answers the client errors Phoenix would
  otherwise render itself, such as an unknown route or a malformed URI, as
  problem details. Anything else is re-raised for the usual error handling.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: PortalAPI.Router.init(opts)

  @impl Plug
  def call(conn, opts) do
    PortalAPI.Router.call(conn, opts)
  rescue
    exception ->
      # The router wraps what its plugs raise; the status lives on the reason.
      {conn, reason} = unwrap(exception, conn)
      status = Plug.Exception.status(reason)

      if status in 400..499 do
        PortalAPI.ProblemDetails.send(conn, status, detail(status))
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  defp unwrap(%Plug.Conn.WrapperError{conn: conn, kind: :error, reason: reason}, _conn),
    do: {conn, reason}

  defp unwrap(exception, conn), do: {conn, exception}

  defp detail(404), do: "The requested resource could not be found."
  defp detail(_status), do: "The request could not be processed."
end
