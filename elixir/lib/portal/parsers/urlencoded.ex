defmodule Portal.Parsers.URLENCODED do
  @moduledoc """
  Form parser that carries the latest connection when decoding fails.

  Plug.Parsers.URLENCODED raises after reading the body without including the
  updated connection, and Plug.Parsers drops it for oversized bodies. Error
  responses must use that connection.
  """
  @behaviour Plug.Parsers

  @impl true
  def init(opts) do
    opts = Keyword.put_new(opts, :length, 1_000_000)
    Keyword.pop(opts, :body_reader, {Plug.Conn, :read_body, []})
  end

  @impl true
  def parse(conn, "application", "x-www-form-urlencoded", _headers, {{mod, fun, args}, opts}) do
    case apply(mod, fun, [conn, opts | args]) do
      {:ok, body, conn} ->
        Portal.Conn.wrap_errors(conn, fn conn ->
          validate_utf8 = Keyword.get(opts, :validate_utf8, true)
          params = Plug.Conn.Query.decode(body, [], Plug.Parsers.BadEncodingError, validate_utf8)
          {:ok, params, conn}
        end)

      {:more, _data, conn} ->
        Plug.Conn.WrapperError.reraise(
          conn,
          :error,
          Plug.Parsers.RequestTooLargeError.exception([]),
          []
        )

      {:error, :timeout} ->
        raise Plug.TimeoutError

      {:error, _} ->
        raise Plug.BadRequestError
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
