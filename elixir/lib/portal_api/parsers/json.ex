defmodule PortalAPI.Parsers.JSON do
  @moduledoc """
  JSON parser that carries the latest connection when decoding fails.

  Plug.Parsers.JSON raises after reading the body without including the updated
  connection. Error responses must use that connection, especially on keep-alive
  requests where the adapter tracks the bytes already consumed.
  """
  @behaviour Plug.Parsers

  @impl true
  def init(opts) do
    # Retain Plug's validation of the configured decoder.
    Plug.Parsers.JSON.init(opts)
    opts
  end

  @impl true
  def parse(conn, "application", subtype, _headers, opts) do
    if subtype == "json" or String.ends_with?(subtype, "+json") do
      {module, function, args} = Keyword.get(opts, :body_reader, {Plug.Conn, :read_body, []})
      decode(apply(module, function, [conn, opts | args]), opts)
    else
      {:next, conn}
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp decode({:ok, "", conn}, _opts), do: {:ok, %{}, conn}

  defp decode({:ok, body, conn}, opts) do
    decoder = Keyword.fetch!(opts, :json_decoder)
    {module, function, args} = if is_atom(decoder), do: {decoder, :decode!, []}, else: decoder

    terms =
      try do
        apply(module, function, [body | args])
      rescue
        exception ->
          error = Plug.Parsers.ParseError.exception(exception: exception)
          Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
      end

    params =
      if is_map(terms) and not Keyword.get(opts, :nest_all_json, false),
        do: terms,
        else: %{"_json" => terms}

    {:ok, params, conn}
  end

  defp decode({:more, _body, conn}, _opts) do
    # Plug.Parsers otherwise discards this updated conn when raising for size.
    Plug.Conn.WrapperError.reraise(
      conn,
      :error,
      Plug.Parsers.RequestTooLargeError.exception([]),
      []
    )
  end

  defp decode({:error, :timeout}, _opts), do: raise(Plug.TimeoutError)
  defp decode({:error, _}, _opts), do: raise(Plug.BadRequestError)
end
