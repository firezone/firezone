defmodule Portal.CertCache do
  @moduledoc """
  Caches TLS certificate chain and private key for use in Bandit's sni_fun.

  Each instance is started with a `fetch_fn` that returns PEM data.
  The parsed DER cert chain and key are held in GenServer state.
  """
  use GenServer

  require Logger

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    %{id: name, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns SSL options for sni_fun.
  """
  def get_opts(name) do
    GenServer.call(name, :get_opts)
  end

  @doc """
  Triggers an async cert refresh.
  """
  def refresh(name) do
    send(name, :refresh)
  end

  @doc """
  Parses PEM-encoded certificate and key into DER format
  suitable for Erlang's `:ssl` options.
  """
  def parse_pem(cert_pem, key_pem) do
    certs =
      for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(cert_pem), do: der

    key =
      :public_key.pem_decode(key_pem)
      |> Enum.find_value(fn
        {type, der, :not_encrypted}
        when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
          {type, der}

        _ ->
          nil
      end)

    [cert: certs, key: key]
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    fetch_fn = Keyword.fetch!(opts, :fetch_fn)
    cert_opts = fetch_and_parse!(fetch_fn)
    {:ok, %{fetch_fn: fetch_fn, cert_opts: cert_opts}}
  end

  @impl true
  def handle_call(:get_opts, _from, state) do
    {:reply, state.cert_opts, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    case fetch_and_parse(state.fetch_fn) do
      {:ok, cert_opts} ->
        {:noreply, %{state | cert_opts: cert_opts}}

      {:error, reason} ->
        Logger.warning("CertCache refresh failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # -- Private helpers --

  defp fetch_and_parse!(fetch_fn) do
    case fetch_and_parse(fetch_fn) do
      {:ok, opts} -> opts
      {:error, reason} -> raise "CertCache initial load failed: #{inspect(reason)}"
    end
  end

  defp fetch_and_parse(fetch_fn) do
    with {:ok, cert_pem, key_pem} <- fetch_fn.(),
         [cert: [_ | _], key: {_, _}] = opts <- parse_pem(cert_pem, key_pem) do
      {:ok, opts}
    else
      {:error, _} = error -> error
      [cert: [], key: _] -> {:error, :no_certificate_found_in_pem}
      [cert: _, key: nil] -> {:error, :no_private_key_found_in_pem}
    end
  rescue
    e -> {:error, e}
  end
end
