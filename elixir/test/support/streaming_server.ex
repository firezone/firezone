defmodule Portal.StreamingServer do
  @moduledoc """
  Answers HTTP requests from a real Bandit listener on loopback. `Req.Test`
  builds the whole response before the client reads it, so only a socket shows
  how much of a body a client actually took.
  """

  @behaviour Plug

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @impl Plug
  def init(fun), do: fun

  @impl Plug
  def call(conn, fun), do: fun.(conn)

  @doc """
  Starts a listener that answers every request with `fun` and returns its base URL.
  """
  def start(fun) do
    server =
      start_supervised!(
        {Bandit, plug: {__MODULE__, fun}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  Sends up to `count` chunks of `chunk_bytes` each, stops when the client goes
  away, and sends `{:bytes_sent, bytes}` to `pid`.
  """
  def send_chunks(conn, pid, chunk_bytes, count) do
    chunk = :binary.copy("0", chunk_bytes)
    conn = Plug.Conn.send_chunked(conn, 200)

    {conn, sent} =
      Enum.reduce_while(1..count, {conn, 0}, fn _index, {conn, sent} ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> {:cont, {conn, sent + chunk_bytes}}
          {:error, _reason} -> {:halt, {conn, sent}}
        end
      end)

    send(pid, {:bytes_sent, sent})
    conn
  end

  @doc """
  Sends one byte every `interval` milliseconds, until the client goes away.
  """
  def drip(conn, interval) do
    conn = Plug.Conn.send_chunked(conn, 200)
    drip_loop(conn, interval)
  end

  defp drip_loop(conn, interval) do
    Process.sleep(interval)

    case Plug.Conn.chunk(conn, "0") do
      {:ok, conn} -> drip_loop(conn, interval)
      {:error, _reason} -> conn
    end
  end
end
