defmodule Portal.EndpointServer do
  @moduledoc """
  Serves an endpoint over a real Bandit listener. `Plug.Test` never enforces
  Bandit's connection usage counter, so only a request over a socket shows a
  response that was sent on a stale conn.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  defmodule Dispatch do
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, {endpoint, prepare}) do
      Portal.Config.put_env_override(:portal, Portal.Endpoint, https: nil)
      conn |> prepare.() |> endpoint.call(endpoint.init([]))
    end
  end

  @doc """
  Starts the listener and returns its port. `:prepare` runs in the request
  process before the endpoint, for per-process config overrides.
  """
  def start(opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, Portal.Endpoint)
    prepare = Keyword.get(opts, :prepare, & &1)

    server =
      start_supervised!(
        {Bandit,
         plug: {Dispatch, {endpoint, prepare}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: []]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end

  def request(port, method, path, headers, body) do
    %Finch.Response{} =
      Finch.build(method, "http://127.0.0.1:#{port}#{path}", headers, body)
      |> Finch.request!(Req.Finch)
  end

  @doc "Sends raw HTTP/1.1 bytes and returns everything written back before the server closes."
  def send_raw(port, data) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
    :ok = :gen_tcp.send(socket, data)
    response = receive_until_closed(socket, "")
    :gen_tcp.close(socket)
    response
  end

  def raw_request(method, path, headers, body, host \\ "127.0.0.1") do
    [
      method,
      " ",
      path,
      " HTTP/1.1\r\nHost: ",
      host,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "Content-Length: ",
      Integer.to_string(IO.iodata_length(body)),
      "\r\n\r\n",
      body
    ]
  end

  defp receive_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_until_closed(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> raise "HTTP connection failed: #{inspect(reason)}"
    end
  end
end
