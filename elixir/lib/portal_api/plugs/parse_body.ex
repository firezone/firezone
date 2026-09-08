defmodule PortalAPI.Plugs.ParseBody do
  @moduledoc """
  `Plug.Parsers` that answers a body it cannot decode with problem details
  instead of the exception Phoenix would otherwise render.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    exception in Plug.Conn.WrapperError ->
      case exception do
        %{kind: :error, reason: %Plug.Parsers.ParseError{}, conn: conn} -> parse_error(conn)
        _ -> reraise(exception, __STACKTRACE__)
      end
  end

  defp parse_error(conn) do
    PortalAPI.ProblemDetails.send(conn, 400, "The request body could not be parsed.")
  end
end
