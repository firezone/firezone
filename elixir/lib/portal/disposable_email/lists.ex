defmodule Portal.DisposableEmail.Lists do
  @moduledoc """
  Keeps the confirmed and suspected disposable email domain lists in memory on every node.

  The lists are maintained by whoever runs the portal and loaded from the URLs in
  `SIGN_UP_CONFIRMED_DISPOSABLE_DOMAINS_URL` and `SIGN_UP_SUSPECTED_DISPOSABLE_DOMAINS_URL`,
  `https://` or `file://`. Each node loads them on start and checks them for changes every
  refresh interval, using the ETag so an unchanged `https://` list is not downloaded again.
  `Portal.Ops.reload_disposable_email_lists/0` reloads them on every node at once.

  A list that fails to load or parse keeps its previous contents, so a bad upload never
  clears it. Until a list loads for the first time it is empty and retried more often.

  The lists are stored in `:persistent_term` so sign-ups read them without a message to this
  process. They change rarely, which is what `:persistent_term` is meant for.
  """
  use GenServer
  require Logger

  @kinds [:confirmed, :suspected]
  @max_bytes 10 * 1024 * 1024
  @retry_interval :timer.seconds(30)
  @azure_storage_scope "https://storage.azure.com/"
  @azure_storage_api_version "2020-12-06"

  @type kind :: :confirmed | :suspected
  @type result :: :ok | :not_modified | :not_configured | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Returns the domains of a list, or an empty set when it is not configured or not loaded yet.
  """
  @spec domains(kind(), GenServer.name()) :: MapSet.t(String.t())
  def domains(kind, name \\ __MODULE__) when kind in @kinds do
    :persistent_term.get({__MODULE__, name, kind}, MapSet.new())
  end

  @doc """
  Reloads both lists now and returns the result for each.
  """
  @spec reload(GenServer.name(), timeout()) :: %{kind() => result()}
  def reload(name \\ __MODULE__, timeout \\ :timer.seconds(30)) do
    GenServer.call(name, :reload, timeout)
  end

  @doc """
  Fetches a list. Returns `:not_modified` when an `https://` list still has the given ETag.
  """
  @spec fetch(String.t(), String.t() | nil, keyword()) ::
          {:ok, binary(), String.t() | nil} | :not_modified | {:error, term()}
  def fetch(url, etag, opts \\ []) do
    case URI.parse(url) do
      %URI{scheme: "file", host: host, path: path} when host in [nil, ""] and is_binary(path) ->
        read_file(path)

      %URI{scheme: "https"} ->
        fetch_https(url, etag, opts)

      _other ->
        {:error, :unsupported_url}
    end
  end

  @doc """
  Parses a list into a set of lowercased domains.

  Rejects the whole list when any line is not a domain, e.g. when an error page was served
  instead of the list.
  """
  @spec parse(binary()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def parse(body) do
    cond do
      byte_size(body) > @max_bytes ->
        {:error, :too_large}

      not String.valid?(body) ->
        {:error, :invalid_encoding}

      true ->
        body
        |> String.split(["\r\n", "\n"])
        |> Enum.with_index(1)
        |> Enum.map(fn {line, number} -> {line |> String.trim() |> String.downcase(), number} end)
        |> Enum.reject(fn {line, _number} -> line == "" or String.starts_with?(line, "#") end)
        |> Enum.reduce_while({:ok, MapSet.new()}, &put_domain/2)
    end
  end

  defp put_domain({line, number}, {:ok, domains}) do
    if domain?(line),
      do: {:cont, {:ok, MapSet.put(domains, String.trim_trailing(line, "."))}},
      else: {:halt, {:error, {:invalid_line, number}}}
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Portal.Config.get_env(:portal, __MODULE__, []), opts)

    state = %{
      name: Keyword.fetch!(config, :name),
      urls: %{confirmed: config[:confirmed_url], suspected: config[:suspected_url]},
      etags: %{},
      loaded: MapSet.new(),
      refresh_interval: Keyword.fetch!(config, :refresh_interval),
      fetch_opts: [
        azure_managed_identity: Keyword.get(config, :azure_managed_identity, false),
        req_opts: Keyword.get(config, :req_opts, [])
      ]
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    {_results, state} = load(state)
    {:noreply, schedule_refresh(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_results, state} = load(state)
    {:noreply, schedule_refresh(state)}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {results, state} = load(state)
    {:reply, results, state}
  end

  defp load(state) do
    Enum.reduce(@kinds, {%{}, state}, fn kind, {results, state} ->
      {result, state} = load(kind, state.urls[kind], state)
      {Map.put(results, kind, result), state}
    end)
  end

  defp load(_kind, nil, state), do: {:not_configured, state}

  defp load(kind, url, state) do
    with {:ok, body, etag} <- fetch(url, state.etags[kind], state.fetch_opts),
         {:ok, domains} <- parse(body) do
      if domains != domains(kind, state.name) do
        :persistent_term.put({__MODULE__, state.name, kind}, domains)
        Logger.info("Loaded disposable email domain list", list: kind, count: MapSet.size(domains))
      end

      {:ok, %{state | etags: Map.put(state.etags, kind, etag), loaded: MapSet.put(state.loaded, kind)}}
    else
      :not_modified ->
        {:not_modified, state}

      {:error, reason} ->
        Logger.error("Failed to load disposable email domain list, keeping the previous one",
          list: kind,
          reason: inspect(reason)
        )

        {{:error, reason}, state}
    end
  end

  # A list that never loaded is retried sooner, so a node that started during an outage
  # does not stay without it for a whole refresh interval.
  defp schedule_refresh(state) do
    pending? = Enum.any?(@kinds, &(state.urls[&1] && not MapSet.member?(state.loaded, &1)))
    interval = if pending?, do: min(@retry_interval, state.refresh_interval), else: state.refresh_interval
    Process.send_after(self(), :refresh, interval)
    state
  end

  defp read_file(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- if(size > @max_bytes, do: {:error, :too_large}, else: :ok),
         {:ok, body} <- File.read(path) do
      {:ok, body, nil}
    end
  end

  defp fetch_https(url, etag, opts) do
    with {:ok, auth_headers} <- auth_headers(opts) do
      headers = if etag, do: [{"if-none-match", etag} | auth_headers], else: auth_headers

      [url: url, headers: headers, decode_body: false, receive_timeout: :timer.seconds(15)]
      |> Keyword.merge(Keyword.get(opts, :req_opts, []))
      |> Req.new()
      |> Req.get()
      |> case do
        {:ok, %Req.Response{status: 200, body: body} = response} ->
          {:ok, body, response |> Req.Response.get_header("etag") |> List.first()}

        {:ok, %Req.Response{status: 304}} ->
          :not_modified

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  defp auth_headers(opts) do
    if Keyword.get(opts, :azure_managed_identity, false) do
      token = Portal.Azure.ManagedIdentity.access_token!(@azure_storage_scope)
      {:ok, [{"authorization", "Bearer " <> token}, {"x-ms-version", @azure_storage_api_version}]}
    else
      {:ok, []}
    end
  rescue
    exception -> {:error, {:managed_identity, exception}}
  end

  defp domain?(line) do
    byte_size(line) <= 253 and Regex.match?(~r/^[a-z0-9-]+(\.[a-z0-9-]+)+\.?$/, line)
  end
end
